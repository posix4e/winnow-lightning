import Foundation
import Network
import WalletCore
import XCTest
@testable import LightningCore

private final class SessionJournal: LightningJournal {
    private var bytes: Data?
    func load() -> Data? { bytes }
    func store(_ snapshot: Data) { bytes = snapshot }
}

/// A real localhost BOLT 8 peer, with no Bitcoin funding or external service.
private actor SessionPeer {
    let secret = Data(repeating: 2, count: 32)
    private let listener: NWListener
    private var connection: NWConnection?
    private var transport: LightningTransport?
    private var messages: [Data] = []

    init() throws { listener = try NWListener(using: .tcp) }

    func listen() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "winnow.test.lightning.listener"))
        }
    }
    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "winnow.test.lightning.peer"))
    }
    func handshake(features: LightningFeatures = .channelOpening) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while connection == nil {
            guard ContinuousClock.now < deadline else { throw LightningError.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        let handshake = try LightningHandshake(role: .responder, localSecret: secret)
        let actOne = try await exact(50)
        try await write(XCTUnwrap(handshake.receive(actOne).reply))
        let actThree = try await exact(66)
        transport = try XCTUnwrap(handshake.receive(actThree).transport)
        _ = try LightningFeatures.readInitialization(await receive())
        try await send(features.initialization())
    }
    func send(_ message: LightningWire.Message) async throws {
        try await write(XCTUnwrap(transport).encrypt(message.bytes))
    }
    func receive() async throws -> LightningWire.Message {
        while messages.isEmpty {
            messages.append(contentsOf: try XCTUnwrap(transport).receive(await read(maximum: 65_536)))
        }
        return try .init(bytes: messages.removeFirst())
    }
    func close() { connection?.cancel(); listener.cancel(); transport?.close() }
    private func exact(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await read(maximum: count - bytes.count)) }
        return bytes
    }
    private func read(maximum: Int) async throws -> Data {
        let connection = try XCTUnwrap(connection)
        let timeout = Task { try await Task.sleep(for: .seconds(3)); connection.cancel() }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: LightningError.closed) }
            }
        }
    }
    private func write(_ bytes: Data) async throws {
        let connection = try XCTUnwrap(connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

final class PeerSessionTests: XCTestCase, @unchecked Sendable {
    func testChainScanKeepsControlTrafficAliveAndDefersChannelProcessing() async throws {
        let remote = try SessionPeer(), port = try await remote.listen()
        let peer = try ChannelKeys.publicKey(secret: remote.secret)
        let chain = Data(repeating: 7, count: 32)
        let engine = try LightningEngine(chain: chain, journal: SessionJournal())
        try await engine.chainCaughtUp()
        let session = LightningPeerSession(engine: engine, peer: peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let handshake = Task { try await remote.handshake() }
        do {
            try await session.start(); try await handshake.value
            await engine.chainDisconnected()
            let terms = try ChannelSecrets().terms(capacity: 100_000)
            let open = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: 3, count: 32),
                capacity: 100_000, pushMsat: 0, feePerKW: 1000, terms: terms)
            try await remote.send(open.message())
            var warning = LightningWire.Writer(); warning.append(Data(repeating: 0, count: 32))
            warning.u16(4); warning.append(Data("wait".utf8))
            try await remote.send(.init(type: 1, payload: warning.data))
            var ping = LightningWire.Writer(); ping.u16(2); ping.u16(0)
            try await remote.send(.init(type: 18, payload: ping.data))
            let pong = try await remote.receive()
            XCTAssertEqual(pong.type, 19)
            XCTAssertEqual(pong.payload, Data([0, 2, 0, 0]))
            let pausedChannels = await engine.channels(), warningText = await session.lastPeerWarning
            XCTAssertTrue(pausedChannels.isEmpty, "No channel decision may be made while the chain is unverified")
            XCTAssertEqual(warningText, "Provider warning: wait")
            try await engine.chainCaughtUp()
            let accepted = try await remote.receive()
            XCTAssertEqual(accepted.type, 33, "The queued open must resume after verification, without another inbound message")
            let channels = await engine.channels(), status = await session.status
            XCTAssertEqual(channels.first?.phase, .accepted)
            XCTAssertEqual(status, .connected)
            try await remote.send(.init(type: 17, payload: warning.data))
            let deadline = ContinuousClock.now + .seconds(3)
            while await session.status == .connected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let failed = await session.status
            XCTAssertEqual(failed, .failed("Provider error: wait"))
            let retained = await engine.channels()
            XCTAssertEqual(retained.first?.id, channels.first?.id)
            await session.stop(); await remote.close()
        } catch {
            await session.stop(); await remote.close(); handshake.cancel(); throw error
        }
    }
}

extension PeerSessionTests {
    func testCanceledRouteQueryDrainsAndKeepsPingAliveBeforeAnotherQuery() async throws {
        let remote = try SessionPeer(), port = try await remote.listen(), peer = try ChannelKeys.publicKey(secret: remote.secret)
        let chain = NetworkParams.regtest.genesisHash
        let engine = try LightningEngine(chain: chain, journal: SessionJournal())
        try await engine.chainCaughtUp(height: 100)
        let session = LightningPeerSession(engine: engine, peer: peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let features = try LightningFeatures(bits: LightningFeatures.channelOpening.bits.union([7]))
        let handshake = Task { try await remote.handshake(features: features) }
        let now = UInt64(Date().timeIntervalSince1970)
        let invoice = try Bolt11Invoice.encode(network: .regtest, amountMsat: 5000, hash: Data(repeating: 1, count: 32),
            secret: Data(repeating: 2, count: 32), nodeSecret: Data(repeating: 3, count: 32), route: nil, timestamp: now)
        do {
            try await session.start(); try await handshake.value
            let first = Task { try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000) }
            let query = try await remote.receive(); XCTAssertEqual(query.type, 263)
            do { _ = try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000); XCTFail("Queries overlapped") } catch {}
            first.cancel(); do { _ = try await first.value; XCTFail() } catch is CancellationError {}
            await engine.chainDisconnected()
            var ping = LightningWire.Writer(); ping.u16(2); ping.u16(0)
            try await remote.send(.init(type: 18, payload: ping.data))
            let pong = try await remote.receive(); XCTAssertEqual(pong.type, 19)
            var reply = LightningWire.Writer(); reply.append(chain); reply.u32(0); reply.u32(101); reply.u8(1); reply.u16(1); reply.u8(0)
            try await remote.send(.init(type: 264, payload: reply.data))
            let deadline = ContinuousClock.now + .seconds(3)
            while await session.gossipQuery != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let remaining = await session.gossipQuery; XCTAssertNil(remaining)
            try await engine.chainCaughtUp(height: 100)
            let second = Task { try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000) }
            let next = try await remote.receive(); XCTAssertEqual(next.type, 263)
            let deadlineTime = UInt64(Date().timeIntervalSince1970) + 700
            await session.testRoutingProgress(now: deadlineTime)
            await session.checkRoutingTimeout(now: deadlineTime)
            do { _ = try await second.value; XCTFail("Timeout kept continuation alive") } catch {}
            let status = await session.status, channels = await engine.channels(), payments = await engine.payments()
            XCTAssertEqual(status, .stopped); XCTAssertTrue(channels.isEmpty); XCTAssertTrue(payments.isEmpty)
            await remote.close()
        } catch { await session.stop(); await remote.close(); handshake.cancel(); throw error }
    }
}

private extension LightningPeerSession {
    func testRoutingProgress(now: UInt64) { gossipQuery?.lastProgress = now }
}
