import WalletCore
import ChainWatchCore
import Foundation
import Testing

@Test func detectsExactFundingOutputAndSpend() throws {
    let script = Data([0x00, 0x20] + Array(repeating: 0x42, count: 32))
    let funding = Transaction(version: 2,
                              inputs: [Transaction.Input(previousOutput: .init(txid: Data(repeating: 0x01, count: 32), vout: 0),
                                                         scriptSig: Data(), sequence: 0xffff_ffff)],
                              outputs: [Transaction.Output(value: 10_000, scriptPubKey: script)], locktime: 0)
    let outpoint = try FundingOutpoint(txid: funding.txid, vout: 0)
    let spend = Transaction(version: 2,
                            inputs: [Transaction.Input(previousOutput: .init(txid: funding.txid, vout: 0),
                                                       scriptSig: Data(), sequence: 0xffff_ffff)],
                            outputs: [Transaction.Output(value: 9_000, scriptPubKey: Data([0x51]))], locktime: 0)
    let watcher = ChannelWatch(scriptPubKey: script, fundingOutpoint: outpoint)
    let events = watcher.events(height: 12, transactions: [funding, spend])
    #expect(events.count == 2)
    #expect(events[0].kind == .fundingOutput)
    #expect(events[0].amountSats == 10_000)
    #expect(events[1].kind == .fundingSpend)
    #expect(outpoint.displayText == "\(HexBytes.displayHash(funding.txid)):0")
}

@Test func journalDeduplicatesAndRollsBackDisconnectedBlocks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = Data([0x51])
    let watch = ChannelWatch(scriptPubKey: script)
    let url = directory.appendingPathComponent("events.json")
    let journal = try EventJournal(url: url, network: "regtest", watch: watch)
    try await journal.ensureStored()
    let settled = WatchedEvent(kind: .fundingOutput, height: 10,
                               transactionID: "a", vout: 0, amountSats: 100)
    let orphaned = WatchedEvent(kind: .fundingOutput, height: 11,
                                transactionID: "b", vout: 0, amountSats: 200)
    #expect(try await journal.record([settled, orphaned]).count == 2)
    #expect(try await journal.record([settled]).isEmpty)
    try await journal.rollBack(to: 10)
    #expect(await journal.events() == [settled])
    let reopened = try EventJournal(url: url, network: "regtest", watch: watch)
    #expect(await reopened.events() == [settled])
    #expect(throws: ChainWatchError.changedWatch) {
        try EventJournal(url: url, network: "regtest", watch: ChannelWatch(scriptPubKey: Data([0x52])))
    }
    #expect(throws: ChainWatchError.changedWatch) {
        try EventJournal(url: url, network: "signet", watch: watch)
    }
}
