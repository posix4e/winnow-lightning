import Foundation
import Network
import WalletCore

/// Lightning sockets only. Bitcoin sockets remain in Winnow's PeerPool.
/// One receive is outstanding per peer. Native output sequence numbers preserve
/// wire order when actor continuations for chain and peer work resume out of order.
public actor LightningTCP {
    private struct Peer {
        let connection: NWConnection
        var nextSequence: UInt64 = 0
        var output: [UInt64: LightningPacket] = [:]
        var writing = false
        var receiving = false
        var processing = false
        var input: Data?
        var readable = true
        var nativeReady = false
    }
    private let engine: LightningEngine
    private let onUpdate: @Sendable (LightningSnapshot) async throws -> Void
    private let onError: @Sendable (String) async -> Void
    private var peers: [UInt64: Peer] = [:]
    private var nextID: UInt64 = 1
    private var ready = false
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var listener: NWListener?

    public init(engine: LightningEngine,
                onUpdate: @escaping @Sendable (LightningSnapshot) async throws -> Void,
                onError: @escaping @Sendable (String) async -> Void) {
        self.engine = engine; self.onUpdate = onUpdate; self.onError = onError
    }

    public func start() {
        guard timer == nil, !stopped else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }

    public func connect(host: String, port: UInt16, nodeID: String, kemKey: String,
                        signatureKey: String) async throws {
        guard !stopped, peers.count < 16, let port = NWEndpoint.Port(rawValue: port), nextID < UInt64.max else { throw LightningError.closed }
        let pin = try await engine.pinPeer(nodeID: nodeID, kemKey: kemKey, signatureKey: signatureKey)
        guard pin.chain_ready else { throw LightningError.native("chain catch-up required") }
        try await consume(pin)
        let id = nextID; nextID += 1
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        peers[id] = Peer(connection: connection)
        do {
            try await connected(connection, id: id)
            guard !stopped, peers[id] != nil else { throw LightningError.closed }
            let result = try await engine.connect(connection: id, nodeID: nodeID, kemKey: kemKey)
            peers[id]?.nativeReady = true
            try await consume(result)
            receive(id)
        } catch { await disconnect(id); throw error }
    }

    /// A listener is useful for a second research device or local integration tests.
    public func listen(port: UInt16 = 0) async throws -> UInt16 {
        guard !stopped, listener == nil, try await engine.status().chain_ready else { throw LightningError.closed }
        let incoming = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener = incoming
        incoming.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            incoming.stateUpdateHandler = { state in
                switch state {
                case .ready: incoming.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): incoming.stateUpdateHandler = nil; continuation.resume(throwing: error)
                case .cancelled: incoming.stateUpdateHandler = nil; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            incoming.start(queue: DispatchQueue(label: "winnow.lightning.listener"))
        }
        guard let bound = incoming.port?.rawValue else { throw LightningError.invalidResponse }
        return bound
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped, peers.count < 16, nextID < UInt64.max else { connection.cancel(); return }
        let id = nextID; nextID += 1
        peers[id] = Peer(connection: connection)
        do {
            try await connected(connection, id: id)
            let result = try await engine.accept(connection: id)
            peers[id]?.nativeReady = true
            try await consume(result)
            receive(id)
        } catch { await onError(error.localizedDescription); await disconnect(id) }
    }

    private func connected(_ connection: NWConnection, id: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "winnow.lightning.socket.\(id)"))
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    if connection.state != .ready { connection.cancel() }
                }
            }
    }

    public func consume(_ snapshot: LightningSnapshot) async throws {
        guard !stopped else { return }
        ready = snapshot.chain_ready
        for packet in snapshot.packets ?? [] {
            guard var peer = peers[packet.connection] else { continue }
            guard packet.sequence >= peer.nextSequence, peer.output[packet.sequence] == nil,
                  peer.output.count < 256,
                  peer.output.values.reduce(packet.bytes.count, { $0 + $1.bytes.count }) <= 4_194_304 else {
                await disconnect(packet.connection)
                throw LightningError.native("Lightning socket queue exceeded its bound")
            }
            peer.output[packet.sequence] = packet
            peers[packet.connection] = peer
            write(packet.connection)
        }
        try await onUpdate(snapshot)
        for id in Array(peers.keys) {
            await processInput(id)
            receive(id)
        }
    }

    private func write(_ id: UInt64) {
        guard var peer = peers[id], !peer.writing, let packet = peer.output[peer.nextSequence],
              let data = (packet.bytes.isEmpty ? Data() : Data(hex: packet.bytes)) else { return }
        peer.writing = true
        peers[id] = peer
        if data.isEmpty { Task { await self.written(id, error: nil) }; return }
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { await self?.written(id, error: error) }
        })
    }

    private func written(_ id: UInt64, error: NWError?) async {
        guard var peer = peers[id], let packet = peer.output.removeValue(forKey: peer.nextSequence) else { return }
        if let error { await onError(error.localizedDescription); await disconnect(id); return }
        peer.nextSequence += 1
        peer.writing = false
        peer.readable = packet.resume_read
        peers[id] = peer
        if packet.closed { await disconnect(id); return }
        write(id)
        await processInput(id)
        receive(id)
    }

    private func receive(_ id: UInt64) {
        guard ready, var peer = peers[id], peer.nativeReady, peer.readable, !peer.receiving, !peer.processing, peer.input == nil else { return }
        peer.receiving = true
        peers[id] = peer
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { await self?.received(id, data: data, complete: complete, error: error) }
        }
    }

    private func received(_ id: UInt64, data: Data?, complete: Bool, error: NWError?) async {
        guard var peer = peers[id] else { return }
        peer.receiving = false
        peer.input = data
        peers[id] = peer
        await processInput(id)
        if complete || error != nil { await disconnect(id) } else { receive(id) }
    }

    private func processInput(_ id: UInt64) async {
        guard ready, var peer = peers[id], peer.nativeReady, peer.readable, !peer.processing, let data = peer.input, !data.isEmpty else { return }
        peer.processing = true
        peers[id] = peer
        do {
            let snapshot = try await engine.read(connection: id, bytes: data)
            peers[id]?.input = nil
            // Keep processing set while consume reenters this actor.
            try await consume(snapshot)
            peers[id]?.processing = false
        } catch LightningError.native("chain catch-up required") {
            peers[id]?.processing = false; ready = false
        } catch LightningError.native("peer input is paused") {
            peers[id]?.processing = false; peers[id]?.readable = false
        } catch {
            await onError(error.localizedDescription)
            await disconnect(id)
        }
    }

    private func poll() async {
        guard !stopped else { return }
        do {
            let state = try await engine.status()
            let snapshot = try await (state.chain_ready ? engine.tick() : engine.drain())
            try await consume(snapshot)
        } catch LightningError.native("chain catch-up required") { ready = false }
          catch { if !stopped { await onError(error.localizedDescription) } }
    }

    private func disconnect(_ id: UInt64) async {
        peers.removeValue(forKey: id)?.connection.cancel()
        if let snapshot = try? await engine.disconnect(connection: id) { try? await consume(snapshot) }
    }

    public func stop() async {
        stopped = true
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        let active = peers
        peers.removeAll()
        for (id, peer) in active {
            peer.connection.cancel()
            _ = try? await engine.disconnect(connection: id)
        }
    }
}
