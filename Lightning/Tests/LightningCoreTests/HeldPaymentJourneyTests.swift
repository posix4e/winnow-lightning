#if os(macOS)
import Foundation
import CryptoKit
import Testing
import WalletCore
import TestSupport
@testable import LightningCore

/// Disposable protocol proof: S -> A -> B -> R. RPC creates the chain and
/// checks mining/relay; Winnow constructs every funding transaction and feeds
/// verified headers/filters to each native engine.
@Suite("Four-node held-payment protocol", .serialized)
struct HeldPaymentJourneyTests {
    static var scenarios: [String] {
        if let scenario = ProcessInfo.processInfo.environment["WINNOW_CLAIM_CASE"] { return [scenario] }
        return ["reconnect", "force-close", "provider-restart", "timeout", "provider-down", "race", "recipient-restart", "force-close-reorg", "non-overlap"]
    }
    private actor Mesh {
        var engines: [LightningEngine]
        var stopped: Set<Int> = []
        var queue: [(Int, UInt64, Data)] = []
        init(_ engines: [LightningEngine]) { self.engines = engines }
        func engine(_ index: Int) -> LightningEngine { engines[index] }
        func live(_ indices: [Int]) -> [Int] { indices.filter { !stopped.contains($0) } }
        func selected(_ indices: [Int]) -> [LightningEngine] { indices.map { engines[$0] } }
        func tick(_ indices: [Int]) async throws {
            for i in indices { try accept(i, await engines[i].tick()) }
        }
        func step() async throws {
            if queue.isEmpty {
                for (i, engine) in engines.enumerated() where !stopped.contains(i) {
                    try accept(i, await engine.drain())
                }
            }
            guard !queue.isEmpty else { return }
            let (destination, connection, bytes) = queue.removeFirst()
            try accept(destination, await engines[destination].read(connection: connection, bytes: bytes))
        }
        func closeAll() async { for engine in engines { await engine.close() } }
        func replace(_ index: Int, _ engine: LightningEngine) {
            engines[index] = engine
            stopped.remove(index)
        }
        func stop(_ index: Int) {
            stopped.insert(index)
            queue.removeAll { $0.0 == index || $0.1 == UInt64(index + 1) }
        }
        func accept(_ source: Int, _ snapshot: LightningSnapshot) throws {
            for packet in snapshot.packets ?? [] {
                let destination = Int(packet.connection) - 1
                guard !stopped.contains(destination), !packet.closed, !packet.bytes.isEmpty else { continue }
                let bytes = try #require(Data(hex: packet.bytes))
                for offset in stride(from: 0, to: bytes.count, by: 65_536) {
                    queue.append((destination, UInt64(source + 1), bytes.subdata(in: offset..<min(offset + 65_536, bytes.count))))
                }
            }
        }
        func pump() async throws -> Bool {
            for _ in 0..<1000 {
                if queue.isEmpty {
                    for (i, engine) in engines.enumerated() where !stopped.contains(i) {
                        try accept(i, await engine.drain())
                    }
                    if queue.isEmpty {
                        for (i, engine) in engines.enumerated() where !stopped.contains(i) {
                            if try await !engine.status().chain_ready { return false }
                        }
                        return true
                    }
                }
                let (destination, connection, bytes) = queue[0]
                if try await !engines[destination].status().chain_ready { return false }
                queue.removeFirst()
                try accept(destination, await engines[destination].read(connection: connection, bytes: bytes))
            }
            throw LightningChainError.catchUpDidNotConverge
        }
    }

    @Test("Recipient settles through a different provider while sender is terminated",
          .enabled(if: ProcessInfo.processInfo.environment["WINNOW_BITCOIN_DIR"] != nil), arguments: scenarios)
    func offlineSender(scenario: String) async throws {
        let forceClose = scenario.hasPrefix("force-close")
        let node = try RegtestNode()
        defer { node.stop() }
        let state = node.directory.appendingPathComponent("four-node")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let wallet = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(),
            storageURL: state.appendingPathComponent("wallet.json"), entropy: testEntropy, creationHeight: 1)
        let address = try await wallet.freshReceiveAddress()
        try node.rpc(["createwallet", "bank"])
        let mining = try node.rpc(["getnewaddress"], wallet: "bank")
        try node.rpc(["generatetoaddress", "101", mining], wallet: "bank")
        try node.rpc(["sendtoaddress", address, "0.02"], wallet: "bank")
        try node.rpc(["generatetoaddress", "1", mining], wallet: "bank")
        try await node.waitForFilters()
        let pool = PeerPool(params: .regtest, peerCount: 1,
            manualPeers: [PeerEndpoint(host: "127.0.0.1", port: node.p2pPort)])
        await pool.start()
        defer { Task { await pool.stop() } }
        let headers = try HeaderChain(params: .regtest)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: state.appendingPathComponent("relay.json"))
        defer { Task { await broadcaster.shutdown() } }
        func make(_ i: Int) throws -> LightningEngine {
            try LightningEngine(seed: Data(repeating: UInt8(71 + i), count: 32),
                storageURL: state.appendingPathComponent("node-\(i)"), network: .regtest,
                feeRateSatPerVByte: 2, allowPrivateForwarding: i == 1 || i == 2, enableClaims: true,
                claimProvider: i == 1 ? LightningClaimProvider(host: "127.0.0.1", port: 9735) : nil)
        }
        let engines = try (0..<4).map(make)
        defer { Task { for engine in engines { await engine.close() } } }
        let mesh = Mesh(engines)
        func scan(_ active: [Int]) async throws {
            let active = await mesh.live(active)
            let driver = LightningChainDriver(engines: await mesh.selected(active), headers: headers)
            try await driver.sync(using: filters, walletScripts: wallet.watchScripts(),
                onUpdate: { index, snapshot in try await mesh.accept(active[index], snapshot) },
                onReorg: { height in
                    try await wallet.rollBack(to: height)
                    try await broadcaster.rollBack(to: height)
                }, onMatch: { match in
                    try await wallet.apply(match: match)
                    for tx in match.block.transactions { try await broadcaster.markConfirmed(tx.txid, atHeight: match.height) }
                })
        }
        func settle(_ active: [Int]) async throws {
            for _ in 0..<12 {
                if try await mesh.pump() { return }
                try await scan(active)
            }
            throw LightningChainError.catchUpDidNotConverge
        }
        try await scan([0,1,2,3])
        let identities = try await engines.asyncMap { try await $0.status() }
        for (i, engine) in engines.enumerated() {
            for (j, peer) in identities.enumerated() where i != j {
                _ = try await engine.pinPeer(nodeID: peer.node_id, kemKey: peer.kem_key, signatureKey: peer.signature_key)
            }
        }
        // Only these channel edges exist. Recipient R has no channel to A.
        for source in 0..<3 {
            let destination = source + 1
            let peer = identities[destination]
            try await mesh.accept(destination, engines[destination].accept(connection: UInt64(source + 1)))
            try await mesh.accept(source, engines[source].connect(connection: UInt64(destination + 1),
                nodeID: peer.node_id, kemKey: peer.kem_key))
            try await settle([0,1,2,3])
            try await mesh.accept(source, engines[source].openChannel(nodeID: peer.node_id,
                amountSat: 200_000, userChannelID: UInt64(700 + source)))
            try await settle([0,1,2,3])
            let request = try #require(try await engines[source].status().events.values.first { $0.kind == "funding" })
            let requestID = try #require(request.fundingRequestID)
            let script = try #require(request.script.flatMap { Data(hex: $0) })
            let reservation = try await wallet.reserveChannelFunding(requestID: requestID, amount: 200_000,
                scriptPubKey: script, feeRateSatPerVByte: 2, chainTip: headers.height)
            let submitted = try await wallet.markFundingSubmitted(requestID: requestID)
            try await mesh.accept(source, engines[source].submitFunding(request: request, reservation: submitted))
            try await settle([0,1,2,3])
            let authorized = try #require(try await engines[source].status().events.first {
                $0.value.kind == "broadcast" && $0.value.transactions == [reservation.rawTransaction.hex]
            })
            let txid = try await broadcaster.broadcast(reservation.rawTransaction, feeRateSatPerVByte: 2)
            try await wallet.commitFundingBroadcast(requestID: requestID, rawTransaction: reservation.rawTransaction)
            try await mesh.accept(source, engines[source].acknowledge(eventID: authorized.key))
            for _ in 0..<250 {
                if try node.rpc(["getrawmempool"]).contains(txid.displayHex) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(node.rpc(["getrawmempool"]).contains(txid.displayHex))
            try node.rpc(["generatetoaddress", "6", mining], wallet: "bank")
            try await node.waitForFilters()
            try await scan([0,1,2,3])
            try await settle([0,1,2,3])
        }
        #expect(try await mesh.engine(3).status().channels.count == 1)
        #expect(try await mesh.engine(3).status().channels.first?.node_id == identities[2].node_id)

        let initialSenderLiquidity = try #require(try await engines[0].status().channels.first?.outbound_capacity_msat)
        // A peer-only connection carries claim control messages. R still has
        // no channel to A: the payout must use A -> B -> R.
        try await mesh.accept(1, mesh.engine(1).accept(connection: 4))
        try await mesh.accept(3, mesh.engine(3).connect(connection: 2,
            nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
        try await settle([0,1,2,3])
        if scenario == "non-overlap" {
            // The recipient is absent for the entire quote/funding/export phase.
            await mesh.stop(3)
            await mesh.engine(3).close()
            _ = try await engines[1].disconnect(connection: 4)
            _ = try await engines[2].disconnect(connection: 4)
        }
        try await mesh.accept(0, engines[0].prepareClaim(requestID: "offline-claim",
            provider: identities[1].node_id, host: "127.0.0.1", port: 9735, amountMsat: 5_000_000))
        for _ in 0..<100 {
            try await settle([0,1,2,3])
            try await mesh.tick(await mesh.live([0,1,2,3]))
            if try await engines[0].status().claims.values.first?.state == "quoted" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let quote = try #require(try await engines[0].status().claims.values.first)
        try #require(quote.state == "quoted")
        let terms = try #require(quote.terms)
        let hash = try #require(Data(hex: terms.payment_hash))
        await #expect(throws: LightningError.self) { _ = try await engines[0].exportClaim(id: quote.claim_id) }
        try await mesh.accept(0, engines[0].commitClaim(quote))
        try await mesh.accept(0, engines[0].commitClaim(quote))
        for _ in 0..<120 {
            try await settle([0,1,2,3])
            try await mesh.tick(await mesh.live([0,1,2,3]))
            if try await engines[0].status().claims[quote.claim_id]?.state == "awaiting_claim" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle([0,1,2,3])
        try #require(try await mesh.engine(1).status().hash_invoices[hash.hex]?.state == "held")
        let outgoing = try #require(try await engines[0].status().channels.first?.outbound_htlcs.first)
        #expect(outgoing.committed && !outgoing.is_dust)
        #expect(outgoing.payment_hash == hash.hex && outgoing.amount_msat == 5_100_000)
        let token = try await engines[0].exportClaim(id: quote.claim_id)
        #expect(try await engines[0].exportClaim(id: quote.claim_id) == token)
        let envelopeBytes = try #require(Data(hex: String(token.dropFirst("wlnclaim1:".count))))
        let fields = try #require(JSONSerialization.jsonObject(with: envelopeBytes) as? [String: Any])
        let preimage = try #require((fields["preimage"] as? String).flatMap { Data(hex: $0) })
        // A clean native destruction proves there is no sender engine available
        // to approve the recipient payment or supply a preimage.
        await mesh.stop(0)
        await engines[0].close()
        try await mesh.accept(1, mesh.engine(1).disconnect(connection: 1))
        if scenario == "non-overlap" {
            await mesh.replace(3, try make(3))
            try await scan([1,2,3])
            try await mesh.accept(2, engines[2].accept(connection: 4))
            try await mesh.accept(3, mesh.engine(3).connect(connection: 3,
                nodeID: identities[2].node_id, kemKey: identities[2].kem_key))
            try await mesh.accept(1, engines[1].accept(connection: 4))
            try await mesh.accept(3, mesh.engine(3).connect(connection: 2,
                nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
            try await settle([1,2,3])
        }
        if scenario == "provider-down" {
            // Neither the sender nor the provider participates while expiry
            // passes. On return S must recover via its own channel monitor.
            await mesh.stop(1)
            await mesh.engine(1).close()
            _ = try await engines[2].disconnect(connection: 2)
            _ = try await mesh.engine(3).disconnect(connection: 2)
            let height = try #require(UInt32(node.rpc(["getblockcount"])))
            try node.rpc(["generatetoaddress", String(outgoing.cltv_expiry + 4 - height), mining], wallet: "bank")
            try await node.waitForFilters()
            try await scan([2,3])
            let recoveredSender = try make(0)
            await mesh.replace(0, recoveredSender)
            try await scan([0,2,3])
            let balanceBefore = await wallet.balance
            let recoveryAddress = try await wallet.freshReceiveAddress()
            let recoveryScript = try AddressDecoder.scriptPubKey(for: recoveryAddress, network: .regtest)
            var broadcastCount = 0
            for round in 0..<4 {
                let snapshot = try await recoveredSender.status()
                for event in snapshot.events.values where event.kind == "sweep_required" {
                    try await mesh.accept(0, recoveredSender.sweepOutputs(outputID: #require(event.output_id), destinationScript: recoveryScript))
                }
                var expected: [String] = []
                for (id, event) in try await recoveredSender.status().events where event.kind == "broadcast" {
                    let package = try #require(event.transactions)
                    // The app's existing relay currently supports individually
                    // fee-paying legacy transactions only; detect any package
                    // requirement here before allowing this recovery in UI.
                    try #require(package.count == 1, "Unexpected required recovery package")
                    for raw in package {
                        let bytes = try #require(Data(hex: raw))
                        let txid = try await broadcaster.broadcast(bytes, feeRateSatPerVByte: 2)
                        expected.append(txid.displayHex)
                        broadcastCount += 1
                    }
                    try await mesh.accept(0, recoveredSender.acknowledge(eventID: id))
                }
                for _ in 0..<250 {
                    let mempool = try node.rpc(["getrawmempool"])
                    if expected.allSatisfy({ mempool.contains($0) }) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let mempool = try node.rpc(["getrawmempool"])
                try #require(expected.allSatisfy { mempool.contains($0) }, "Timeout relay round \(round) did not reach Core")
                try node.rpc(["generatetoaddress", round == 1 ? "150" : "6", mining], wallet: "bank")
                try await node.waitForFilters()
                try await scan([0,2,3])
                try await settle([0,2,3])
            }
            #expect(broadcastCount >= 3)
            #expect(try await recoveredSender.status().claims[quote.claim_id]?.state == "failed")
            #expect(try await mesh.engine(3).status().hash_invoices[hash.hex]?.state != "received")
            #expect(await wallet.balance > balanceBefore + 190_000)
            #expect(await wallet.utxos.contains { $0.scriptPubKey == recoveryScript })
            await mesh.closeAll()
            await broadcaster.shutdown()
            await pool.stop()
            return
        }
        if scenario == "timeout" {
            _ = try await mesh.engine(3).importClaim(token)
            let deadline = try #require(try await mesh.engine(1).status().hash_invoices[hash.hex]?.claim_deadline)
            let height = try #require(UInt32(node.rpc(["getblockcount"])))
            try node.rpc(["generatetoaddress", String(deadline + 1 - height), mining], wallet: "bank")
            try await node.waitForFilters()
            try await scan([1,2,3])
            try await settle([1,2,3])
            await #expect(throws: LightningError.self) { _ = try await mesh.engine(3).redeemClaim(id: quote.claim_id) }
            #expect(try await mesh.engine(3).status().claims[quote.claim_id]?.state == "expired")
            #expect(try await mesh.engine(1).status().payments[hash.hex] == nil)
            let recoveredSender = try make(0)
            await mesh.replace(0, recoveredSender)
            try await scan([0,1,2,3])
            try await mesh.accept(1, mesh.engine(1).accept(connection: 1))
            try await mesh.accept(0, recoveredSender.connect(connection: 2,
                nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
            try await settle([0,1,2,3])
            for _ in 0..<100 {
                try await mesh.tick([0,1,2,3])
                try await settle([0,1,2,3])
                if try await recoveredSender.status().claims[quote.claim_id]?.state == "failed" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await recoveredSender.status().claims[quote.claim_id]?.state == "failed")
            #expect(try await recoveredSender.status().channels.first?.outbound_capacity_msat == initialSenderLiquidity)
            await mesh.closeAll()
            await broadcaster.shutdown()
            await pool.stop()
            return
        }
        let inspected = try await mesh.engine(3).inspectClaim(token)
        #expect(inspected.claim_id == quote.claim_id && inspected.amount_msat == 5_000_000)
        _ = try await mesh.engine(3).importClaim(token)
        #expect(try await mesh.engine(3).importClaim(token).claims.count == 1)
        #expect(try await mesh.engine(3).status().claims[quote.claim_id]?.state == "ready")
        try await mesh.accept(3, mesh.engine(3).redeemClaim(id: quote.claim_id))
        if scenario == "race" {
            _ = try await engines[2].importClaim(token)
            try await mesh.accept(2, engines[2].redeemClaim(id: quote.claim_id))
        }
        if scenario == "recipient-restart" {
            for _ in 0..<30 {
                try await mesh.step()
                if try await mesh.engine(1).status().payments[hash.hex] != nil { break }
            }
            try #require(try await mesh.engine(1).status().payments[hash.hex]?.state == "pending")
            await mesh.stop(3)
            await mesh.engine(3).close()
            _ = try await mesh.engine(1).disconnect(connection: 4)
            _ = try await engines[2].disconnect(connection: 4)
            let recoveredRecipient = try make(3)
            await mesh.replace(3, recoveredRecipient)
            try await scan([1,2,3])
            try await mesh.accept(2, engines[2].accept(connection: 4))
            try await mesh.accept(3, recoveredRecipient.connect(connection: 3,
                nodeID: identities[2].node_id, kemKey: identities[2].kem_key))
            try await mesh.accept(1, mesh.engine(1).accept(connection: 4))
            try await mesh.accept(3, recoveredRecipient.connect(connection: 2,
                nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
        }
        if scenario == "provider-restart" {
            // Stop A after it durably binds the invoice and starts the outgoing
            // payment, but before its packet reaches B. Reestablishment must
            // replay that same payment, not fund a second attempt.
            for _ in 0..<30 {
                try await mesh.step()
                if try await mesh.engine(1).status().payments[hash.hex] != nil { break }
            }
            try #require(try await mesh.engine(1).status().payments[hash.hex]?.state == "pending")
            await mesh.stop(1)
            await mesh.engine(1).close()
            _ = try await engines[2].disconnect(connection: 2)
            _ = try await mesh.engine(3).disconnect(connection: 2)
            let recoveredProvider = try make(1)
            await mesh.replace(1, recoveredProvider)
            try await scan([1,2,3])
            try await mesh.accept(2, engines[2].accept(connection: 2))
            try await mesh.accept(1, recoveredProvider.connect(connection: 3,
                nodeID: identities[2].node_id, kemKey: identities[2].kem_key))
            try await mesh.accept(1, recoveredProvider.accept(connection: 4))
            try await mesh.accept(3, mesh.engine(3).connect(connection: 2,
                nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
        }
        for _ in 0..<200 {
            try await settle([1,2,3])
            try await mesh.tick([1,2,3])
            if try await mesh.engine(3).status().hash_invoices[hash.hex]?.state == "received" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await settle([1,2,3])
        #expect(try await mesh.engine(3).status().hash_invoices[hash.hex]?.state == "received")
        #expect(try await mesh.engine(1).status().payments[hash.hex]?.state == "sent")
        #expect(try await mesh.engine(3).status().events.values.contains {
            $0.kind == "payment_received" && $0.payment_hash == hash.hex && $0.amount_msat == 5_000_000
        })
        // Repeating the exact binding must not create another payout.
        try await mesh.accept(3, mesh.engine(3).redeemClaim(id: quote.claim_id))
        try await settle([1,2,3])
        #expect(try await mesh.engine(3).status().claims[quote.claim_id]?.state == "received")
        // A copied bearer string cannot redirect an already bound payout.
        _ = try await engines[2].importClaim(token)
        try await mesh.accept(2, engines[2].redeemClaim(id: quote.claim_id))
        try await settle([1,2,3])
        #expect(try await engines[2].status().claims[quote.claim_id]?.state != "received")
        #expect(try await engines[2].status().events.values.contains { $0.kind == "claim_request_rejected" })
        if forceClose {
            let inbound = try #require(try await mesh.engine(1).status().channels.first { $0.node_id == identities[0].node_id })
            try await mesh.accept(1, mesh.engine(1).forceClose(inbound))
            // Core produces all commitment and HTLC-success bytes; Winnow
            // submits them. No RPC broadcast or synthetic preimage recovery.
            var witnessedPreimage = false
            var reorgExercised = false
            for round in 0..<3 {
                var expected: [String] = []
                for i in [1,2,3] {
                    for (id, event) in try await mesh.engine(i).status().events where event.kind == "broadcast" {
                        for raw in try #require(event.transactions) {
                            let bytes = try #require(Data(hex: raw))
                            let txid = try await broadcaster.broadcast(bytes, feeRateSatPerVByte: 2)
                            expected.append(txid.displayHex)
                        }
                        try await mesh.accept(i, mesh.engine(i).acknowledge(eventID: id))
                    }
                }
                // Observable relay completion precedes mining, including the
                // second-stage HTLC success transaction after its parent.
                for _ in 0..<250 {
                    let mempool = try node.rpc(["getrawmempool"])
                    if expected.allSatisfy({ mempool.contains($0) }) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let mempool = try node.rpc(["getrawmempool"])
                try #require(expected.allSatisfy { mempool.contains($0) }, "Recovery relay round \(round): expected \(expected), mempool \(mempool)")
                let mined = try node.rpc(["generatetoaddress", scenario == "force-close-reorg" ? "1" : "6", mining], wallet: "bank")
                let blocks = try JSONDecoder().decode([String].self, from: Data(mined.utf8))
                for block in blocks {
                    if try node.rpc(["getblock", block, "2"]).contains(preimage.hex) { witnessedPreimage = true }
                }
                try await node.waitForFilters()
                try await scan([1,2,3])
                try await settle([1,2,3])
                if scenario == "force-close-reorg" && witnessedPreimage && !reorgExercised {
                    // Reorg a freshly observed preimage spend, before six
                    // confirmations, without erasing the learned secret or
                    // resurrecting the provider's already settled payout.
                    let lastBlock = try #require(blocks.last)
                    try node.rpc(["invalidateblock", lastBlock])
                    let alternateMining = try node.rpc(["getnewaddress"], wallet: "bank")
                    try node.rpc(["generatetoaddress", "2", alternateMining], wallet: "bank")
                    try await node.waitForFilters()
                    try await scan([1,2,3])
                    try await settle([1,2,3])
                    #expect(try await mesh.engine(1).status().payments[hash.hex]?.state == "sent")
                    #expect(try await mesh.engine(3).status().claims[quote.claim_id]?.state == "received")
                    reorgExercised = true
                }
            }
            if scenario == "force-close-reorg" {
                #expect(reorgExercised)
                try node.rpc(["generatetoaddress", "6", mining], wallet: "bank")
                try await node.waitForFilters()
                try await scan([1,2,3])
            }
            #expect(witnessedPreimage, "The provider must publish the preimage on chain before sender recovery")
            #expect(try await mesh.engine(1).status().channels.allSatisfy { $0.node_id != identities[0].node_id })
        }
        let restored = try make(0)
        defer { Task { await restored.close() } }
        await mesh.replace(0, restored)
        let recovery = LightningChainDriver(engines: [restored], headers: headers)
        try await recovery.sync(using: filters, walletScripts: [],
            onUpdate: { _, snapshot in try await mesh.accept(0, snapshot) }, onMatch: { _ in })
        if !forceClose {
        try await mesh.accept(1, mesh.engine(1).accept(connection: 1))
        try await mesh.accept(0, restored.connect(connection: 2,
            nodeID: identities[1].node_id, kemKey: identities[1].kem_key))
        _ = try await mesh.pump()
        }
        let senderState = try await restored.status()
        #expect(senderState.payments[hash.hex]?.state == "sent", "Sender state: \(senderState.payments[hash.hex]?.state ?? "missing"); events \(senderState.events.values.map { $0.kind }); height \(senderState.height)")
        #expect(try await mesh.engine(1).status().hash_invoices[hash.hex]?.state == "received")
        #expect(try await restored.status().claims[quote.claim_id]?.state == "paid")
        if !forceClose {
            try await mesh.accept(0, restored.prepareClaim(requestID: "next-unfunded-quote",
                provider: identities[1].node_id, host: "127.0.0.1", port: 9735, amountMsat: 5_000_000))
            for _ in 0..<60 {
                _ = try await mesh.pump()
                try await mesh.tick([0,1,2,3])
                if try await restored.status().claims.values.contains(where: { $0.state == "quoted" }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let secondQuote = try #require(try await restored.status().claims.values.first { $0.state == "quoted" })
            try await mesh.accept(0, restored.cancelClaim(id: secondQuote.claim_id))
            for _ in 0..<60 {
                _ = try await mesh.pump()
                try await mesh.tick([0,1,2,3])
                if try await restored.status().claims[secondQuote.claim_id] == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await restored.status().claims[secondQuote.claim_id] == nil)
            #expect(try await restored.status().payments.count == 1)
        }
        await restored.close()
        await mesh.closeAll()
        await broadcaster.shutdown()
        await pool.stop()
    }
}

private extension Array where Element: Sendable {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
#endif
