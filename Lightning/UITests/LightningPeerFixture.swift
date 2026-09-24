import Foundation
import LightningCore
import TestSupport
import WalletCore

/// A real second node in the UI-test runner. Only the fixture uses Core RPC;
/// both Lightning peers scan and relay using Winnow over Bitcoin P2P.
actor LightningPeerFixture {
    let engine: LightningEngine
    private let pool: PeerPool
    private let filters: FilterSync
    private let driver: LightningChainDriver
    private let broadcaster: TxBroadcaster
    private var transport: LightningTCP?
    private var loop: Task<Void, Never>?
    private var relaying = false
    private var failure: String?

    init(directory: URL) throws {
        engine = try LightningEngine(seed: Data(repeating: 72, count: 32),
            storageURL: directory.appending(path: "peer"), network: .regtest, feeRateSatPerVByte: 2)
        pool = PeerPool(params: .regtest, peerCount: 1,
            manualPeers: [PeerEndpoint(host: BitcoinCLI.nodeHost, port: BitcoinCLI.p2pPort)])
        let chain = try HeaderChain(params: .regtest)
        filters = try FilterSync(pool: pool, chain: chain, startHeight: 1, requiredCheckpointPeers: 1)
        driver = LightningChainDriver(engines: [engine], headers: chain)
        broadcaster = try TxBroadcaster(pool: pool, storageURL: directory.appending(path: "relay.json"))
    }

    func start() async throws -> UInt16 {
        await pool.start()
        let tcp = LightningTCP(engine: engine, onUpdate: { [weak self] state in
            try await self?.update(state)
        }, onError: { [weak self] error in await self?.report(error) })
        transport = tcp
        try await scan()
        await tcp.start()
        let port = try await tcp.listen()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.scan()
                    try await Task.sleep(for: .seconds(3))
                } catch is CancellationError { return }
                  catch FilterSyncError.peersCoolingDown { await self?.logNetworkRetry() }
                  catch FilterSyncError.noPeers { await self?.logNetworkRetry() }
                  catch PeerPoolHeaderSyncError.allPeersCoolingDown { await self?.logNetworkRetry() }
                  catch { await self?.report(String(describing: error)); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return port
    }

    func peerCard() async throws -> String {
        let state = try await engine.status()
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "node_id": state.node_id, "kem_key": state.kem_key, "signature_key": state.signature_key,
        ], options: [.sortedKeys]), as: UTF8.self)
    }

    func invoice(_ id: String) async throws -> LightningInvoice {
        let state = try await engine.createInvoice(requestID: id, amountMsat: 2_000_000)
        try await transport?.consume(state)
        guard let invoice = state.invoices[id] else { throw LightningError.invalidResponse }
        return invoice
    }

    func status() async throws -> LightningSnapshot {
        if let failure { throw LightningError.native("Fixture: " + failure) }
        return try await engine.status()
    }

    private func logNetworkRetry() async {
        print("LIGHTNING_FIXTURE_NETWORK_RETRY \(await pool.rejectionReasons)")
    }

    private func report(_ error: String) { failure = error }

    private func scan() async throws {
        guard let transport else { return }
        try await driver.sync(using: filters, walletScripts: [],
            onUpdate: { _, state in try await transport.consume(state) },
            onReorg: { [broadcaster] height in try await broadcaster.rollBack(to: height) },
            onMatch: { [broadcaster] match in
                for tx in match.block.transactions { try await broadcaster.markConfirmed(tx.txid, atHeight: match.height) }
            })
    }

    private func update(_ state: LightningSnapshot) async throws {
        guard state.chain_ready, !relaying, let transport else { return }
        relaying = true
        defer { relaying = false }
        for (id, event) in state.events where event.kind == "broadcast" {
            guard let package = event.transactions, package.count == 1,
                  let raw = package.first.flatMap({ Data(hex: $0) }) else { throw LightningError.invalidResponse }
            _ = try await broadcaster.broadcast(raw, feeRateSatPerVByte: 2)
            try await transport.consume(engine.acknowledge(eventID: id))
        }
    }

    func stop() async {
        loop?.cancel()
        await loop?.value
        await transport?.stop()
        await engine.close()
        await broadcaster.shutdown()
        await pool.stop()
    }

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
