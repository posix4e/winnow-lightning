import Foundation

/// Foreground transport for one authenticated peer. The engine owns every
/// durable decision; reconnecting rebuilds only Noise and publication cursors.
public actor LightningPeerSession {
    public enum Status: Sendable, Equatable { case stopped, connecting, connected, failed(String) }
    private let engine: LightningEngine
    public let peer: Data
    private let host: String, port: UInt16
    private let onEvents: @Sendable ([LightningEngine.Event]) async throws -> Void
    private var connection: LightningConnection?
    private var reader: Task<Void, Never>?, timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sent = Set<UInt64>()
    private var flushing = false
    private var stopping = false
    private var starting = false
    public private(set) var status: Status = .stopped

    public init(engine: LightningEngine, peer: Data, host: String, port: UInt16,
                onEvents: @escaping @Sendable ([LightningEngine.Event]) async throws -> Void) {
        self.engine = engine; self.peer = peer; self.host = host; self.port = port; self.onEvents = onEvents
    }
    @discardableResult
    public func start() async throws -> LightningFeatures {
        guard connection == nil, !stopping, !starting else { throw LightningError.invalidState }
        starting = true; defer { starting = false }
        generation &+= 1
        let epoch = generation
        let transport = try await engine.connection(host: host, port: port, peer: peer)
        guard epoch == generation else { throw CancellationError() }
        connection = transport; status = .connecting; sent.removeAll()
        do {
            try await transport.start()
            try await transport.send(LightningFeatures.asyncClient.initialization())
            let features = try LightningFeatures.readInitialization(await transport.receive())
            guard epoch == generation else { throw CancellationError() }
            try await engine.peerInitialized(peer, features: features)
            status = .connected
            reader = Task { await receiveLoop(transport, epoch: epoch) }
            timer = Task { await publicationLoop(epoch: epoch) }
            try await flush()
            return features
        } catch { await finish(epoch: epoch, error: error); throw error }
    }
    public func stop() async {
        guard !stopping else { return }
        generation &+= 1
        guard let transport = connection else { status = .stopped; return }
        stopping = true; defer { stopping = false }
        reader?.cancel(); timer?.cancel()
        await transport.close(); await engine.peerDisconnected(peer)
        connection = nil; reader = nil; timer = nil; status = .stopped
    }
    /// Reentrant callers share a single ordered publisher. Channel messages
    /// replay only after a new authenticated session; onion publication is
    /// acknowledged to the journal only after the transport accepted its bytes.
    public func flush() async throws {
        guard !flushing, status == .connected, let transport = connection else { return }
        let epoch = generation
        flushing = true; defer { flushing = false }
        guard await engine.chainIsCurrent else { return }
        do {
            try await publishChannel(transport, epoch: epoch)
            try await publishOnions(transport, epoch: epoch)
        } catch LightningError.invalidState {
            if await engine.chainIsCurrent { throw LightningError.invalidState }
        }
    }
    private func publishChannel(_ transport: LightningConnection, epoch: UInt64) async throws {
        for item in try await engine.pendingMessages(peer: peer) where !sent.contains(item.sequence) {
            guard epoch == generation else { throw CancellationError() }
            try await transport.send(item.message)
            guard epoch == generation else { throw CancellationError() }
            sent.insert(item.sequence)
        }
    }
    private func publishOnions(_ transport: LightningConnection, epoch: UInt64) async throws {
        for item in try await engine.pendingOnionMessages(peer: peer, now: Self.now) {
            guard epoch == generation else { throw CancellationError() }
            try await transport.send(item.message)
            guard epoch == generation else { throw CancellationError() }
            try await engine.onionMessagePublished(sequence: item.sequence)
        }
    }
    private func receiveLoop(_ transport: LightningConnection, epoch: UInt64) async {
        do {
            while !Task.isCancelled && epoch == generation {
                let message = try await transport.receive()
                while !(await engine.chainIsCurrent) { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                guard epoch == generation else { return }
                try await handle(message, transport: transport)
                try await flush()
            }
        } catch { await finish(epoch: epoch, error: error) }
    }
    private func publicationLoop(epoch: UInt64) async {
        do {
            while !Task.isCancelled && epoch == generation {
                try await Task.sleep(for: .milliseconds(250))
                let events = try await engine.expireInvoiceRequests(now: Self.now)
                if !events.isEmpty { try await onEvents(events) }
                try await flush()
            }
        } catch { await finish(epoch: epoch, error: error) }
    }
    private func handle(_ message: LightningWire.Message, transport: LightningConnection) async throws {
        switch message.type {
        case 18:
            var reader = LightningWire.Reader(message.payload)
            let count = try reader.u16(), ignored = try reader.u16()
            _ = try reader.take(Int(ignored)); try reader.requireEnd()
            if count < 65_532 {
                var pong = LightningWire.Writer(); pong.u16(count); pong.append(Data(repeating: 0, count: Int(count)))
                try await transport.send(.init(type: 19, payload: pong.data))
            }
        case 513:
            try await onEvents(engine.receiveOnionMessage(message, now: Self.now))
        case 32, 33, 34, 35, 36, 38, 39, 128, 130, 131, 132, 133, 134, 135, 136:
            try await onEvents(engine.receive(peer: peer, message: message))
        case 256, 257, 258: break // Gossip is not used by this configured-route client.
        case 1, 17: throw LightningError.closed
        default:
            guard message.type % 2 == 1 else { throw LightningError.invalidMessage }
        }
    }
    private func finish(epoch: UInt64, error: Error) async {
        guard epoch == generation else { return }
        await stop()
        if generation == epoch &+ 1 { status = .failed(String(describing: error)) }
    }
    private static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }
}

extension LightningEngine {
    func connection(host: String, port: UInt16, peer: Data) throws -> LightningConnection {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        return try LightningConnection(host: host, port: port, secret: state.nodeSecret, peer: peer)
    }
}
