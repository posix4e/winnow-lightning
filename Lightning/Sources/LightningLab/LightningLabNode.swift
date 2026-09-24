import Foundation
import LightningCore
import TestSupport
import WalletCore

/// A regtest lab node. Bitcoin funding, scanning and relay all use Winnow.
/// Lab operators fund its displayed address externally; this type has no RPC.
public actor LightningLabNode {
    public nonisolated let engine: LightningEngine
    public nonisolated let wallet: Wallet
    private let headers: HeaderChain
    private let listenPort: UInt16
    private let pool: PeerPool
    private let filters: FilterSync
    private let driver: LightningChainDriver
    private let broadcaster: TxBroadcaster
    private var transport: LightningTCP?
    private var loop: Task<Void, Never>?
    private var relaying = false
    private var failure: String?
    private var feeRate = FeePolicy.Priority.medium.satPerVByte

    public init(directory: URL, seed: Data, bitcoinPeer: PeerEndpoint,
                listenPort: UInt16 = 0, provider: LightningClaimProvider? = nil,
                forwarding: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        self.listenPort = listenPort
        engine = try LightningEngine(seed: seed, storageURL: directory.appending(path: "peer"),
            network: .regtest, feeRateSatPerVByte: FeePolicy.Priority.medium.satPerVByte,
            allowPrivateForwarding: forwarding,
            enableClaims: true, claimProvider: provider)
        let keys = InMemoryKeyStore()
        let fresh = try Wallet.create(network: .regtest, keyStore: keys,
            entropy: Data(seed.prefix(16)), creationHeight: 1)
        let path = directory.appending(path: "wallet.json")
        if FileManager.default.fileExists(atPath: path.path) {
            wallet = try Wallet.open(storageURL: path, keyStore: keys)
        } else {
            _ = fresh
            wallet = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(),
                storageURL: path, entropy: Data(seed.prefix(16)), creationHeight: 1)
        }
        pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [bitcoinPeer])
        let chain = try HeaderChain(params: .regtest)
        headers = chain
        filters = try FilterSync(pool: pool, chain: chain, startHeight: 1, requiredCheckpointPeers: 1)
        driver = LightningChainDriver(engines: [engine], headers: chain)
        broadcaster = try TxBroadcaster(pool: pool, storageURL: directory.appending(path: "relay.json"))
    }

    public func start() async throws -> UInt16 {
        await pool.start()
        let tcp = LightningTCP(engine: engine, onUpdate: { [weak self] state in
            try await self?.update(state)
        }, onError: { [weak self] error in await self?.report(error) })
        transport = tcp
        try await scan()
        await tcp.start()
        let port = try await tcp.listen(port: listenPort)
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

    public func peerCard() async throws -> String {
        let state = try await engine.status()
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "node_id": state.node_id, "kem_key": state.kem_key, "signature_key": state.signature_key,
        ], options: [.sortedKeys]), as: UTF8.self)
    }

    public func invoice(_ id: String) async throws -> LightningInvoice {
        let state = try await engine.createInvoice(requestID: id, amountMsat: 2_000_000)
        try await transport?.consume(state)
        guard let invoice = state.invoices[id] else { throw LightningError.invalidResponse }
        return invoice
    }

    public func status() async throws -> LightningSnapshot {
        if let failure { throw LightningError.native("Fixture: " + failure) }
        return try await engine.status()
    }

    private func logNetworkRetry() async {
        print("LIGHTNING_FIXTURE_NETWORK_RETRY \(await pool.rejectionReasons)")
    }

    private func report(_ error: String) { failure = error }

    private func scan() async throws {
        guard let transport else { return }
        feeRate = await FeePolicy.resolve(observed: wallet.observedFeeRates,
            floorSatPerVByte: pool.feeFilterFloorSatPerVByte())
        try await transport.consume(engine.setFeeRate(feeRate))
        try await driver.sync(using: filters, walletScripts: wallet.watchScripts(),
            onUpdate: { _, state in try await transport.consume(state) },
            onReorg: { [broadcaster, wallet] height in
                try await wallet.rollBack(to: height)
                try await broadcaster.rollBack(to: height)
            },
            onMatch: { [broadcaster, wallet] match in
                try await wallet.apply(match: match)
                for tx in match.block.transactions { try await broadcaster.markConfirmed(tx.txid, atHeight: match.height) }
            })
    }

    private func update(_ state: LightningSnapshot) async throws {
        guard state.chain_ready, !relaying, let transport else { return }
        relaying = true
        defer { relaying = false }
        for (id, request) in state.events where request.kind == "funding" {
            guard let requestID = request.fundingRequestID, let amount = request.amount_sat,
                  let script = request.script.flatMap({ Data(hex: $0) }) else { throw LightningError.invalidResponse }
            let saved = await wallet.fundingReservations.first { $0.requestID == requestID }
            _ = try await wallet.reserveChannelFunding(requestID: requestID, amount: amount,
                scriptPubKey: script, feeRateSatPerVByte: saved?.feeRateSatPerVByte ?? feeRate,
                chainTip: headers.height)
            let submitted = try await wallet.markFundingSubmitted(requestID: requestID)
            try await transport.consume(engine.submitFunding(request: request, reservation: submitted))
            try await transport.consume(engine.acknowledge(eventID: id))
        }
        for (id, event) in state.events where event.kind == "broadcast" {
            guard let package = event.transactions, package.count == 1,
                  let raw = package.first.flatMap({ Data(hex: $0) }) else { throw LightningError.invalidResponse }
            let saved = await wallet.fundingReservations.first { $0.rawTransaction == raw }
            _ = try await broadcaster.broadcast(raw, feeRateSatPerVByte: saved?.feeRateSatPerVByte)
            if let saved {
                try await wallet.commitFundingBroadcast(requestID: saved.requestID, rawTransaction: raw)
            }
            try await transport.consume(engine.acknowledge(eventID: id))
        }
    }

    public func consume(_ state: LightningSnapshot) async throws {
        guard let transport else { throw LightningError.closed }
        try await transport.consume(state)
    }

    public func pin(card: String) async throws {
        let peer = try JSONDecoder().decode(PeerCard.self, from: Data(card.utf8))
        try await consume(engine.pinPeer(nodeID: peer.node_id, kemKey: peer.kem_key, signatureKey: peer.signature_key))
    }

    private struct PeerCard: Decodable {
        let node_id: String; let kem_key: String; let signature_key: String
    }

    public func connect(card: String, host: String = "127.0.0.1", port: UInt16) async throws {
        let peer = try JSONDecoder().decode(PeerCard.self, from: Data(card.utf8))
        guard let transport else { throw LightningError.closed }
        try await transport.connect(host: host, port: port, nodeID: peer.node_id,
            kemKey: peer.kem_key, signatureKey: peer.signature_key)
    }

    public func openChannel(to node: String, amountSat: UInt64 = 200_000) async throws {
        try await consume(engine.openChannel(nodeID: node, amountSat: amountSat,
            userChannelID: UInt64.random(in: 1...UInt64.max)))
    }

    public func stop() async {
        loop?.cancel()
        await loop?.value
        await transport?.stop()
        await engine.close()
        await broadcaster.shutdown()
        await pool.stop()
    }

}
