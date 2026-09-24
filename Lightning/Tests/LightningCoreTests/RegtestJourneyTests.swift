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

    private func pay(_ engines: [LightningEngine], pair: Pair, requestID: String) async throws {
        let snapshot = try await engines[1].createInvoice(requestID: requestID, amountMsat: 2_000_000)
        let invoice = try #require(snapshot.invoices[requestID])
        #expect(try await engines[1].createInvoice(requestID: requestID, amountMsat: 2_000_000)
            .invoices[requestID]?.invoice == invoice.invoice)
        try await pair.accept(0, engines[0].payInvoice(invoice.invoice, amountMsat: invoice.amount_msat, maxFeeMsat: 1000))
        for _ in 0..<100 {
            _ = try await pair.pump()
            for (index, engine) in engines.enumerated() { try await pair.accept(index, engine.tick()) }
            if try await engines[0].status().payments[invoice.payment_hash]?.state == "sent" { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        _ = try await pair.pump()
        #expect(try await engines[0].status().payments[invoice.payment_hash]?.state == "sent")
        #expect(try await engines[1].status().events.values.contains {
            $0.kind == "payment_received" && $0.payment_hash == invoice.payment_hash && $0.amount_msat == invoice.amount_msat
        })
        let duplicate = try await engines[0].payInvoice(invoice.invoice, amountMsat: invoice.amount_msat, maxFeeMsat: 1000)
        #expect(duplicate.payments[invoice.payment_hash]?.state == "sent")
        #expect(duplicate.packets?.allSatisfy { $0.bytes.isEmpty } != false)
    }

    @discardableResult
    private func relay(_ engines: [LightningEngine], pair: Pair, broadcaster: TxBroadcaster,
                       node: RegtestNode, allowConflictingCommitments: Bool = false) async throws -> [String] {
        var txids: [String] = []
        for (index, engine) in engines.enumerated() {
            let snapshot = try await engine.status()
            #expect(snapshot.chain_ready)
            for (id, event) in snapshot.events where event.kind == "broadcast" {
                let package = try #require(event.transactions)
                // Initial non-anchor channel/sweep paths must not silently split packages.
                #expect(package.count == 1)
                let bytes = try #require(package.first.flatMap { Data(hex: $0) })
                let txid = try await broadcaster.broadcast(bytes, feeRateSatPerVByte: 2)
                txids.append(txid.displayHex)
                try await pair.accept(index, engine.acknowledge(eventID: id))
                for _ in 0..<250 {
                    if try node.rpc(["getrawmempool"]).contains(txid.displayHex) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if try !node.rpc(["getrawmempool"]).contains(txid.displayHex) {
                    let verdict = try node.rpc(["testmempoolaccept", "[\"\(bytes.hex)\"]"])
                    let outpoint = try #require(Transaction.decode(bytes).inputs.first?.previousOutput)
                    let query = "[{\"txid\":\"\(outpoint.txid.displayHex)\",\"vout\":\(outpoint.vout)}]"
                    let spending = try node.rpc(["gettxspendingprevout", query])
                    #expect(allowConflictingCommitments && spending.contains("spendingtxid") && !spending.contains(txid.displayHex)
                        && (verdict.contains("conflict") || verdict.contains("rejecting replacement")),
                        "Unexpected relay rejection: \(verdict)")
                }
            }
        }
        return txids
    }

    @Test("Restart reconciles an unfinished fork and refuses a fork beyond saved ancestry",
          .enabled(if: ProcessInfo.processInfo.environment["WINNOW_BITCOIN_DIR"] != nil))
    func startupFork() async throws {
        let node = try RegtestNode()
        defer { node.stop() }
        try node.rpc(["createwallet", "miner"])
        try node.rpc(["generatetoaddress", "20", node.rpc(["getnewaddress"], wallet: "miner")], wallet: "miner")
        try await node.waitForFilters()
        let pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [PeerEndpoint(host: "127.0.0.1", port: node.p2pPort)])
        await pool.start()
        defer { Task { await pool.stop() } }
        let headers = try HeaderChain(params: .regtest)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let storage = node.directory.appendingPathComponent("lightning")
        let engine = try LightningEngine(seed: Data(repeating: 81, count: 32), storageURL: storage, network: .regtest, feeRateSatPerVByte: 2)
        let driver = LightningChainDriver(engines: [engine], headers: headers)
        try await driver.sync(using: filters, walletScripts: [], onUpdate: { _, _ in }, onMatch: { _ in })
        #expect(try await engine.status().height == 20)
        await engine.close()
        try node.rpc(["invalidateblock", node.rpc(["getblockhash", "19"])])
        try node.rpc(["generatetoaddress", "3", node.rpc(["getnewaddress"], wallet: "miner")], wallet: "miner")
        try await node.waitForFilters()
        // Simulate the cross-store crash window: Winnow saved the new chain,
        // while the stopped Lightning engine still records the old branch.
        try await filters.sync(watchScripts: [], onMatch: { _ in })
        let restored = try LightningEngine(seed: Data(repeating: 81, count: 32), storageURL: storage, network: .regtest, feeRateSatPerVByte: 2)
        let recovery = LightningChainDriver(engines: [restored], headers: headers)
        try await recovery.sync(using: filters, walletScripts: [], onUpdate: { _, _ in }, onMatch: { _ in })
        #expect(try await restored.status().chain_ready)
        #expect(try await restored.status().block_hash == node.rpc(["getbestblockhash"]))
        await restored.close()
        try node.rpc(["invalidateblock", node.rpc(["getblockhash", "5"])])
        try node.rpc(["generatetoaddress", "20", node.rpc(["getnewaddress"], wallet: "miner")], wallet: "miner")
        try await node.waitForFilters()
        try await filters.sync(watchScripts: [], onMatch: { _ in })
        let deep = try LightningEngine(seed: Data(repeating: 81, count: 32), storageURL: storage, network: .regtest, feeRateSatPerVByte: 2)
        defer { Task { await deep.close() } }
        let blocked = LightningChainDriver(engines: [deep], headers: headers)
        await #expect(throws: LightningChainError.recoveryRequired) {
            try await blocked.sync(using: filters, walletScripts: [], onUpdate: { _, _ in }, onMatch: { _ in })
        }
        #expect(try await !deep.status().chain_ready)
        await #expect(throws: LightningError.native("chain catch-up required")) {
            _ = try await deep.accept(connection: 1)
        }
        await deep.close()
        await pool.stop()
    }

    @Test("Winnow funds, pays, restarts, handles a fork, and recovers channel funds",
          .enabled(if: ProcessInfo.processInfo.environment["WINNOW_BITCOIN_DIR"] != nil), arguments: [false, true])
    func channelJourney(forceClose: Bool) async throws {
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
        _ = try await engines[0].pinPeer(nodeID: peer.node_id, kemKey: peer.kem_key, signatureKey: peer.signature_key)
        await #expect(throws: LightningError.native("peer keys differ from pin")) {
            _ = try await engines[0].pinPeer(nodeID: peer.node_id, kemKey: peer.kem_key,
                signatureKey: Data(repeating: 0, count: 1312).hex)
        }
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

        try await pay(engines, pair: pair, requestID: "before-restart")
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

        #expect(try await restored[0].status().payments.values.contains { $0.state == "sent" })
        try await pay(restored, pair: resumedPair, requestID: "after-restart")

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
        let channel = try #require(try await restored[0].status().channels.first)
        let returnAddress = try await wallet.freshReceiveAddress()
        let returnScript = try AddressDecoder.scriptPubKey(for: returnAddress, network: .regtest)
        if forceClose {
            try await resumedPair.accept(0, restored[0].forceClose(channel))
        } else {
            try await resumedPair.accept(0, restored[0].closeChannel(channel, destinationScript: returnScript))
        }
        try await settle(resumedPair, driver: resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        let closures = try await relay(restored, pair: resumedPair, broadcaster: broadcaster, node: node, allowConflictingCommitments: forceClose)
        #expect(!closures.isEmpty)
        try node.rpc(["generatetoaddress", forceClose ? "150" : "6", miningAddress], wallet: "bank")
        try await node.waitForFilters()
        try await scan(resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: resumedPair)
        try await settle(resumedPair, driver: resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster)
        if forceClose {
            let outputs = try await restored[0].status().events.values.filter { $0.kind == "sweep_required" }
            #expect(!outputs.isEmpty)
            for event in outputs {
                try await resumedPair.accept(0, restored[0].sweepOutputs(outputID: #require(event.output_id), destinationScript: returnScript))
            }
            let sweeps = try await relay([restored[0]], pair: resumedPair, broadcaster: broadcaster, node: node)
            #expect(!sweeps.isEmpty)
            try node.rpc(["generatetoaddress", "1", miningAddress], wallet: "bank")
            try await node.waitForFilters()
            try await scan(resumedDriver, filters: filters, wallet: wallet, broadcaster: broadcaster, pair: resumedPair)
        }
        #expect(try await restored[0].status().channels.isEmpty)
        #expect(await wallet.balance > 490_000)
        #expect(await wallet.utxos.contains { $0.scriptPubKey == returnScript })
        for engine in restored { await engine.close() }
        await broadcaster.shutdown()
        await pool.stop()
    }
}
#endif
