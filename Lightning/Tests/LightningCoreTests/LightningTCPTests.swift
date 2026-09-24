import Foundation
import Testing
import WalletCore
@testable import LightningCore

@Suite("Swift Lightning sockets")
struct LightningTCPTests {
    @Test("PQ handshake and channel messages cross real loopback TCP sockets")
    func handshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = try LightningEngine(seed: Data(repeating: 71, count: 32), storageURL: root.appendingPathComponent("alice"), network: .regtest, feeRateSatPerVByte: 2)
        let bob = try LightningEngine(seed: Data(repeating: 72, count: 32), storageURL: root.appendingPathComponent("bob"), network: .regtest, feeRateSatPerVByte: 2)
        let client = LightningTCP(engine: alice, onUpdate: { _ in }, onError: { Issue.record(Comment(rawValue: $0)) })
        let server = LightningTCP(engine: bob, onUpdate: { _ in }, onError: { Issue.record(Comment(rawValue: $0)) })
        defer { Task { await client.stop(); await server.stop(); await alice.close(); await bob.close() } }
        await client.start(); await server.start()
        let port = try await server.listen()
        let identity = try await bob.status()
        try await client.connect(host: "127.0.0.1", port: port, nodeID: identity.node_id,
                                 kemKey: identity.kem_key, signatureKey: identity.signature_key)
        for _ in 0..<100 {
            if try await alice.status().peers.contains(identity.node_id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await alice.status().peers.contains(identity.node_id))
        try await client.consume(alice.openChannel(nodeID: identity.node_id, amountSat: 100_000, userChannelID: 77))
        for _ in 0..<100 {
            if try await alice.status().events.values.contains(where: { $0.kind == "funding" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await alice.status().events.values.contains { $0.kind == "funding" && $0.amount_sat == 100_000 })
        await client.stop(); await server.stop(); await alice.close(); await bob.close()
    }
}
