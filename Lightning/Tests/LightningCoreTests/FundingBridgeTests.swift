import Foundation
import Testing
import WalletCore
import TestSupport
@testable import LightningCore

@Suite("Winnow funding through the native PQLN bridge")
struct FundingBridgeTests {
    private func pump(_ nodes: [LightningEngine], source: Int, initial: LightningSnapshot) async throws {
        var queue: [(Int, LightningSnapshot)] = [(source, initial)]
        for _ in 0..<200 {
            if queue.isEmpty {
                for (index, node) in nodes.enumerated() {
                    let result = try await node.drain()
                    if result.packets?.contains(where: { !$0.bytes.isEmpty }) == true { queue.append((index, result)) }
                }
                if queue.isEmpty { return }
            }
            let (from, result) = queue.removeFirst()
            for packet in result.packets ?? [] {
                #expect(!packet.closed)
                if packet.bytes.isEmpty { continue }
                let bytes = try #require(Data(hex: packet.bytes))
                for start in stride(from: 0, to: bytes.count, by: 65_536) {
                    let response = try await nodes[1 - from].read(connection: 1,
                        bytes: bytes.subdata(in: start..<min(start + 65_536, bytes.count)))
                    queue.append((1 - from, response))
                }
            }
        }
        Issue.record("Peer exchange did not settle")
    }

    @Test("Swift wallet signs the actual requested output; exact bytes wait for native authorization")
    func winnowFunding() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nodes = try [
            LightningEngine(seed: Data(repeating: 1, count: 32), storageURL: dir.appendingPathComponent("a"),
                network: .regtest, feeRateSatPerVByte: 2),
            LightningEngine(seed: Data(repeating: 2, count: 32), storageURL: dir.appendingPathComponent("b"),
                network: .regtest, feeRateSatPerVByte: 2),
        ]
        let peer = try await nodes[1].status()
        _ = try await nodes[1].accept(connection: 1)
        try await pump(nodes, source: 0, initial: nodes[0].connect(connection: 1, nodeID: peer.node_id, kemKey: peer.kem_key))
        try await pump(nodes, source: 0, initial: nodes[0].openChannel(nodeID: peer.node_id, amountSat: 100_000, userChannelID: 42))
        let snapshot = try await nodes[0].status()
        #expect(snapshot.events.values.allSatisfy { $0.kind != "broadcast" })
        let request = try #require(snapshot.events.values.first { $0.kind == "funding" })
        let id = try #require(request.fundingRequestID)
        let amount = try #require(request.amount_sat)
        let script = try #require(request.script.flatMap { Data(hex: $0) })

        // The wallet coins are existing Swift fixtures. Native tests never
        // create a second wallet or sign this funding transaction.
        let keyStore = InMemoryKeyStore()
        let walletURL = dir.appendingPathComponent("wallet.json")
        let (wallet, _) = try await fundedWallet(network: .regtest, storageURL: walletURL, keyStore: keyStore)
        let reservation = try await wallet.reserveChannelFunding(requestID: id, amount: amount,
            scriptPubKey: script, feeRateSatPerVByte: 2, chainTip: snapshot.height)
        #expect(await wallet.spendableUtxos.isEmpty)
        let signed = try reservation.transaction()
        #expect(signed.inputs.allSatisfy { $0.witness.count == 1 && $0.witness[0].count == 64 })
        let submitted = try await wallet.markFundingSubmitted(requestID: id)
        let result = try await nodes[0].submitFunding(request: request, reservation: submitted)
        #expect(result.events.values.allSatisfy { $0.kind != "broadcast" })
        try await pump(nodes, source: 0, initial: result)
        let authorized = try await nodes[0].status()
        let broadcast = try #require(authorized.events.first { $0.value.kind == "broadcast" })
        #expect(broadcast.value.transactions == [reservation.rawTransaction.hex])
        #expect(authorized.channels.first?.funding_txid == signed.txid.displayHex)
        #expect(!authorized.watches.isEmpty)

        // Simulate broadcaster acceptance, then its durable wallet acknowledgment.
        // Real relay/confirmation is covered by the separate regtest journey.
        try await wallet.commitFundingBroadcast(requestID: id, rawTransaction: reservation.rawTransaction)
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.fundingReservations.first?.phase == .broadcast)
        #expect(await reopened.feeBumpableTxids.isEmpty)
        _ = try await nodes[0].acknowledge(eventID: broadcast.key)
        await nodes[0].close()
        await nodes[1].close()
        let restored = try LightningEngine(seed: Data(repeating: 1, count: 32), storageURL: dir.appendingPathComponent("a"),
            network: .regtest, feeRateSatPerVByte: 2)
        #expect(try await restored.status().channels.first?.funding_txid == signed.txid.displayHex)
        await restored.close()
        await #expect(throws: LightningError.closed) { try await restored.status() }
    }

    @Test("Explicit fee units and regtest restriction")
    func boundaries() throws {
        #expect(try LightningEngine.satPerKW(2) == 500)
        #expect(try LightningEngine.satPerKW(1.5) == 375)
        #expect(throws: LightningError.invalidFee) { try LightningEngine.satPerKW(.nan) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: LightningError.native("Lightning is restricted to regtest")) {
            try LightningEngine(seed: Data(repeating: 1, count: 32), storageURL: dir,
                network: .mainnet, feeRateSatPerVByte: 2)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
