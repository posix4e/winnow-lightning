#if os(macOS)
import Foundation
import Testing
import WalletCore
import TestSupport
@testable import LightningCore

/// No Bitcoin RPC client is linked into LightningCore. RPC below only
/// prepares the disposable chain and checks the independent node's result.
@Suite("Live Winnow/PQLN regtest", .serialized)
struct RegtestJourneyTests {
    private actor Pair {
        let engines: [LightningEngine]
        var queued: [(Int, Data)] = []
        init(_ engines: [LightningEngine]) { self.engines = engines }
        func accept(_ source: Int, _ snapshot: LightningSnapshot) throws {
            for packet in snapshot.packets ?? [] {
                #expect(!packet.closed)
                if packet.bytes.isEmpty { continue }
                let bytes = try #require(Data(hex: packet.bytes))
                for offset in stride(from: 0, to: bytes.count, by: 65_536) {
                    queued.append((1 - source, bytes.subdata(in: offset..<min(offset + 65_536, bytes.count))))
                }
            }
        }
        func pump() async throws -> Bool {
            for _ in 0..<200 {
                if queued.isEmpty {
                    for (i, engine) in engines.enumerated() { try accept(i, await engine.drain()) }
                    if queued.isEmpty {
                        for engine in engines where try await !engine.status().chain_ready { return false }
                        return true
                    }
                }
                let (destination, bytes) = queued[0]
                guard try await engines[destination].status().chain_ready else { return false }
                queued.removeFirst()
                try accept(destination, await engines[destination].read(connection: 1, bytes: bytes))
            }
            throw LightningChainError.catchUpDidNotConverge
        }
    }

    private func scan(_ driver: LightningChainDriver, filters: FilterSync, wallet: Wallet,
                      broadcaster: TxBroadcaster, pair: Pair) async throws {
        try await driver.sync(using: filters, walletScripts: wallet.watchScripts(),
            onUpdate: { index, snapshot in try await pair.accept(index, snapshot) },
            onReorg: { height in
                try await wallet.rollBack(to: height)
                try await broadcaster.rollBack(to: height)
            }, onMatch: { match in
                try await wallet.apply(match: match)
                for tx in match.block.transactions { try await broadcaster.markConfirmed(tx.txid, atHeight: match.height) }
            })
        try await wallet.recordScanHeight(filters.nextScanHeight)
    }

    private func settle(_ pair: Pair, driver: LightningChainDriver, filters: FilterSync,
                        wallet: Wallet, broadcaster: TxBroadcaster) async throws {
        for _ in 0..<12 {
            if try await pair.pump() { return }
            try await scan(driver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: pair)
        }
        throw LightningChainError.catchUpDidNotConverge
    }

    @Test("Winnow discovers coins, funds and relays a channel, then confirms it through compact filters",
          .enabled(if: ProcessInfo.processInfo.environment["WINNOW_BITCOIN_DIR"] != nil))
    func fundingAndConfirmation() async throws {
        let node = try RegtestNode()
        defer { node.stop() }
        let state = node.directory.appendingPathComponent("swift")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let wallet = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(),
            storageURL: state.appendingPathComponent("wallet.json"), entropy: testEntropy, creationHeight: 1)
        let address = try await wallet.freshReceiveAddress()
        try node.rpc(["createwallet", "bank"])
        let miningAddress = try node.rpc(["getnewaddress"], wallet: "bank")
        try node.rpc(["generatetoaddress", "101", miningAddress], wallet: "bank")
        try node.rpc(["sendtoaddress", address, "0.005"], wallet: "bank")
        try node.rpc(["generatetoaddress", "1", miningAddress], wallet: "bank")
        try await node.waitForFilters()

        let pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [PeerEndpoint(host: "127.0.0.1", port: node.p2pPort)])
        defer { Task { await pool.stop() } }
        await pool.start()
        #expect(await pool.connectedPeers().count == 1)
        let headers = try HeaderChain(params: .regtest)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1,
            storageURL: state.appendingPathComponent("filters.json"), requiredCheckpointPeers: 1)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: state.appendingPathComponent("relay.json"))
        defer { Task { await broadcaster.shutdown() } }
        let engines = try [
            LightningEngine(seed: Data(repeating: 1, count: 32), storageURL: state.appendingPathComponent("alice"), network: .regtest, feeRateSatPerVByte: 2),
            LightningEngine(seed: Data(repeating: 2, count: 32), storageURL: state.appendingPathComponent("bob"), network: .regtest, feeRateSatPerVByte: 2),
        ]
        defer { Task { for engine in engines { await engine.close() } } }
        let pair = Pair(engines)
        let driver = LightningChainDriver(engines: engines, headers: headers)
        try await scan(driver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: pair)
        #expect(await wallet.balance == 500_000)
        #expect(try await engines[0].status().height == 102)
        let peer = try await engines[1].status()
        try await pair.accept(1, engines[1].accept(connection: 1))
        try await pair.accept(0, engines[0].connect(connection: 1, nodeID: peer.node_id, kemKey: peer.kem_key))
        try await settle(pair, driver: driver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        try await pair.accept(0, engines[0].openChannel(nodeID: peer.node_id, amountSat: 100_000, userChannelID: 42))
        try await settle(pair, driver: driver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        let request = try #require(try await engines[0].status().events.values.first { $0.kind == "funding" })
        let requestID = try #require(request.fundingRequestID)
        let script = try #require(request.script.flatMap { Data(hex: $0) })
        let reservation = try await wallet.reserveChannelFunding(requestID: requestID, amount: 100_000,
            scriptPubKey: script, feeRateSatPerVByte: 2, chainTip: headers.height)
        let submitted = try await wallet.markFundingSubmitted(requestID: requestID)
        try await pair.accept(0, engines[0].submitFunding(request: request, reservation: submitted))
        try await settle(pair, driver: driver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        let snapshot = try await engines[0].status()
        #expect(snapshot.chain_ready)
        let authorized = try #require(snapshot.events.first { $0.value.kind == "broadcast" })
        #expect(authorized.value.transactions == [reservation.rawTransaction.hex])
        let txid = try await broadcaster.broadcast(reservation.rawTransaction, feeRateSatPerVByte: 2)
        try await wallet.commitFundingBroadcast(requestID: requestID, rawTransaction: reservation.rawTransaction)
        try await pair.accept(0, engines[0].acknowledge(eventID: authorized.key))
        for _ in 0..<250 {
            if try node.rpc(["getrawmempool"]).contains(txid.displayHex) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try node.rpc(["getrawmempool"]).contains(txid.displayHex))
        try node.rpc(["generatetoaddress", "6", miningAddress], wallet: "bank")
        try await node.waitForFilters()
        try await scan(driver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: pair)
        try await settle(pair, driver: driver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        #expect(try await engines[0].status().channels.first?.usable == true)
        #expect(try await engines[1].status().channels.first?.usable == true)
        #expect(await wallet.history.first { $0.txid == txid }?.height == 103)
        #expect(await broadcaster.pendingTxids.isEmpty)

        for engine in engines { await engine.close() }
        let restored = try [
            LightningEngine(seed: Data(repeating: 1, count: 32), storageURL: state.appendingPathComponent("alice"), network: .regtest, feeRateSatPerVByte: 2),
            LightningEngine(seed: Data(repeating: 2, count: 32), storageURL: state.appendingPathComponent("bob"), network: .regtest, feeRateSatPerVByte: 2),
        ]
        defer { Task { for engine in restored { await engine.close() } } }
        #expect(try await restored[0].status().height == 108)
        #expect(try await restored[0].status().channels.first?.funding_txid == txid.displayHex)
        #expect(try await !restored[0].status().chain_ready)
        let resumedPair = Pair(restored)
        let resumedDriver = LightningChainDriver(engines: restored, headers: headers)
        try await scan(resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: resumedPair)
        #expect(try await restored[0].status().chain_ready)
        try await resumedPair.accept(1, restored[1].accept(connection: 1))
        try await resumedPair.accept(0, restored[0].connect(connection: 1, nodeID: peer.node_id, kemKey: peer.kem_key))
        try await settle(resumedPair, driver: resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        #expect(try await restored[0].status().channels.first?.usable == true)
        #expect(try await restored[1].status().channels.first?.usable == true)

        // Remove two confirmations, then deliver a longer replacement branch.
        // WalletCore detects the fork before Lightning sees replacement blocks.
        let removed = try node.rpc(["getblockhash", "107"])
        try node.rpc(["invalidateblock", removed])
        try node.rpc(["generatetoaddress", "3", miningAddress], wallet: "bank")
        try await node.waitForFilters()
        try await scan(resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: resumedPair)
        try await settle(resumedPair, driver: resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        #expect(try await restored[0].status().height == 109)
        #expect(try await restored[0].status().block_hash == node.rpc(["getbestblockhash"]))
        #expect(try await restored[0].status().channels.first?.usable == true)
        for engine in restored { await engine.close() }
        await broadcaster.shutdown()
        await pool.stop()
    }
}
#endif
