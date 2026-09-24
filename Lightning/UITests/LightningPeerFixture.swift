import Foundation
import LightningCore
import LightningLab
import TestSupport
import WalletCore

actor LightningPeerFixture {
    let node: LightningLabNode
    var engine: LightningEngine { node.engine }
    init(directory: URL, seed: UInt8 = 72, port: UInt16 = 0, provider: Bool = false) throws {
        node = try LightningLabNode(directory: directory, seed: Data(repeating: seed, count: 32),
            bitcoinPeer: PeerEndpoint(host: BitcoinCLI.nodeHost, port: BitcoinCLI.p2pPort),
            listenPort: port, provider: provider ? LightningClaimProvider(host: "127.0.0.1", port: port) : nil,
            forwarding: true)
    }
    func start() async throws -> UInt16 { try await node.start() }
    func peerCard() async throws -> String { try await node.peerCard() }
    func invoice(_ id: String) async throws -> LightningInvoice { try await node.invoice(id) }
    func status() async throws -> LightningSnapshot { try await node.status() }
    func stop() async { await node.stop() }

    static func mine(_ count: Int) async throws {
        let address = try BitcoinCLI.newAddress(wallet: "lightning-bank")
        try BitcoinCLI.run(["generatetoaddress", String(count), address])
        let height = try BitcoinCLI.run(["getblockcount"])
        for _ in 0..<300 {
            let indexes = try BitcoinCLI.runObject(["getindexinfo"])
            if let index = indexes["basic block filter index"] as? [String: Any],
               index["synced"] as? Bool == true,
               index["best_block_height"] as? Int == Int(height) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LightningError.native("Fixture compact filters did not catch up")
    }
}
