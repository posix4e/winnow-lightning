import Foundation
import XCTest
import WalletCore
@testable import LightningCore

private final class JournalMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var failing = false
    func load() -> Data? { lock.withLock { bytes } }
    func fail() { lock.withLock { failing = true } }
    func store(_ value: Data) throws {
        try lock.withLock { if failing { throw LightningError.storageFailed }; bytes = value }
    }
}
private final class MemoryJournal: LightningJournal {
    let memory: JournalMemory
    init(_ memory: JournalMemory) { self.memory = memory }
    func load() -> Data? { memory.load() }
    func store(_ snapshot: Data) throws { try memory.store(snapshot) }
}

final class ChannelEngineTests: XCTestCase, @unchecked Sendable {
    private let chain = Data(repeating: 7, count: 32)
    private func key(_ byte: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: byte, count: 32)) }
    private func engine(_ memory: JournalMemory, peer: Data, secret: Data? = nil, features: LightningFeatures = .channelOpening) async throws -> LightningEngine {
        let engine = try LightningEngine(chain: chain, nodeSecret: secret, journal: MemoryJournal(memory))
        try await engine.chainCaughtUp()
        try await engine.peerInitialized(peer, features: features)
        return engine
    }
    func testOpeningPersistsEnforceableCommitmentBeforeBroadcast() async throws {
        let aliceKey = try key(1), bobKey = try key(2), aStore = JournalMemory(), bStore = JournalMemory()
        let alice = try await engine(aStore, peer: bobKey, secret: Data(repeating: 1, count: 32)), bob = try await engine(bStore, peer: aliceKey, secret: Data(repeating: 2, count: 32))
        let id = try await alice.openChannel(peer: bobKey, capacitySat: 100_000, feePerKW: 1000)
        let open = try await alice.pendingMessages(peer: bobKey)[0].message
        _ = try await bob.receive(peer: aliceKey, message: open)
        let accept = try await bob.pendingMessages(peer: aliceKey)[0].message
        let events = try await alice.receive(peer: bobKey, message: accept)
        guard case .fundingRequired(let temporary, let amount, let script) = try XCTUnwrap(events.first) else { return XCTFail() }
        XCTAssertEqual(temporary, id); XCTAssertEqual(amount, 100_000)
        let funding = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 1),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])], outputs: [.init(value: 100_000, scriptPubKey: script)], locktime: 0)
        try await alice.provideFunding(temporaryID: id, peer: bobKey, transaction: funding, output: 0)
        let created = try await alice.pendingMessages(peer: bobKey)[0].message
        _ = try await bob.receive(peer: aliceKey, message: created)
        let signed = try await bob.pendingMessages(peer: aliceKey)[0].message
        let bobChannels = await bob.channels()
        XCTAssertNotNil(bobChannels.first?.signedCommitment)
        let beforeInvalid = aStore.load()
        var invalid = Array(signed.payload); invalid[invalid.count - 1] ^= 1
        do {
            _ = try await alice.receive(peer: bobKey, message: .init(type: 35, payload: Data(invalid)))
            XCTFail("An invalid peer signature must not release funding")
        } catch { XCTAssertEqual(error as? LightningError, .invalidSignature) }
        XCTAssertEqual(beforeInvalid, aStore.load())
        let publish = try await alice.receive(peer: bobKey, message: signed)
        guard case .broadcastFunding(let channelID, let raw) = try XCTUnwrap(publish.first) else { return XCTFail() }
        XCTAssertEqual(raw, funding.serialized(includeWitness: true))
        let persisted = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(aStore.load()))
        XCTAssertEqual(persisted.channels.first?.id, channelID)
        XCTAssertNotNil(persisted.channels.first?.signedCommitment)
        _ = try await alice.fundingConfirmed(channelID: channelID, peer: bobKey, transaction: funding, confirmations: 3)
        _ = try await bob.fundingConfirmed(channelID: channelID, peer: aliceKey, transaction: funding, confirmations: 3)
        let aReady = try await alice.pendingMessages(peer: bobKey).first { $0.message.type == 36 }!.message
        let bReady = try await bob.pendingMessages(peer: aliceKey).first { $0.message.type == 36 }!.message
        _ = try await alice.receive(peer: bobKey, message: bReady)
        _ = try await bob.receive(peer: aliceKey, message: aReady)
        let aChannels = await alice.channels(), bChannels = await bob.channels()
        XCTAssertEqual(aChannels.first?.phase, .ready); XCTAssertEqual(bChannels.first?.phase, .ready)
        XCTAssertNotEqual(aChannels.first?.signedCommitment, bChannels.first?.signedCommitment)
        let restored = try LightningEngine(chain: chain, journal: MemoryJournal(aStore))
        let restoredChannels = await restored.channels()
        XCTAssertEqual(restoredChannels.first?.signedCommitment, aChannels.first?.signedCommitment)
        do { _ = try await restored.pendingMessages(peer: bobKey); XCTFail("Restart must wait for verified chain catch-up") } catch {}
    }
    func testDiskFailureStopsSignaturePublicationAndFurtherActions() async throws {
        let store = JournalMemory(), peer = try key(2)
        let engine = try await engine(store, peer: peer)
        _ = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
        let durable = store.load()
        store.fail()
        do { _ = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertEqual(store.load(), durable)
        do { _ = try await engine.pendingMessages(peer: peer); XCTFail("Even an existing outbox freezes after an uncertain write") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
    }
    func testFundingAndPeerIdentityCannotBeSubstituted() async throws {
        let peer = try key(2), otherPeer = try key(3), memory = JournalMemory()
        let engine = try await engine(memory, peer: peer)
        do { _ = try await engine.openChannel(peer: peer, capacitySat: .max, feePerKW: 1000); XCTFail() } catch {}
        let id = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
        let remoteSecrets = try ChannelSecrets(), terms = try remoteSecrets.terms(capacity: 100_000)
        let accept = try ChannelNegotiation.Accept(temporaryID: id, minimumDepth: 3, terms: terms).message()
        try await engine.peerInitialized(otherPeer, features: .channelOpening)
        do { _ = try await engine.receive(peer: otherPeer, message: accept); XCTFail() } catch {}
        _ = try await engine.receive(peer: peer, message: accept)
        let durable = memory.load()
        let wrong = Transaction(version: 2, inputs: [], outputs: [.init(value: 100_000, scriptPubKey: Data([0]))], locktime: 0)
        do { try await engine.provideFunding(temporaryID: id, peer: peer, transaction: wrong, output: 0); XCTFail() } catch {}
        XCTAssertEqual(memory.load(), durable)
    }
    func testJournalEncryptionIntegrityAndExclusiveWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 42, count: 32), plaintext = Data("private channel monitor and revocation secrets".utf8)
        do {
            let journal = try FileLightningJournal(directory: directory, key: key)
            XCTAssertNil(try journal.load())
            try journal.store(plaintext)
            XCTAssertEqual(try journal.load(), plaintext)
            XCTAssertThrowsError(try FileLightningJournal(directory: directory, key: key))
            let disk = try Data(contentsOf: directory.appendingPathComponent("journal.v1"))
            XCTAssertNil(disk.range(of: plaintext))
        }
        do {
            let wrong = try FileLightningJournal(directory: directory, key: Data(repeating: 43, count: 32))
            XCTAssertThrowsError(try wrong.load())
            XCTAssertThrowsError(try wrong.store(plaintext))
        }
        let journal = try FileLightningJournal(directory: directory, key: key)
        XCTAssertEqual(try journal.load(), plaintext)
        let file = directory.appendingPathComponent("journal.v1")
        var disk = try Data(contentsOf: file); disk[disk.endIndex - 1] ^= 1; try disk.write(to: file)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(try journal.store(plaintext))
    }

    private struct Pair {
        let alice: LightningEngine, bob: LightningEngine
        let aliceKey: Data, bobKey: Data, id: Data
        let aliceStore: JournalMemory, bobStore: JournalMemory
    }
    private func pair(holdingPeer: Bool = false) async throws -> Pair {
        let aliceKey = try key(1), bobKey = try key(2), aStore = JournalMemory(), bStore = JournalMemory()
        let alice = try await engine(aStore, peer: bobKey, secret: Data(repeating: 1, count: 32), features: LightningFeatures(bits: LightningFeatures.channelOpening.bits.union(holdingPeer ? [153] : []))), bob = try await engine(bStore, peer: aliceKey, secret: Data(repeating: 2, count: 32))
        let temporary = try await alice.openChannel(peer: bobKey, capacitySat: 100_000, feePerKW: 1000)
        _ = try await bob.receive(peer: aliceKey, message: alice.pendingMessages(peer: bobKey)[0].message)
        let events = try await alice.receive(peer: bobKey, message: bob.pendingMessages(peer: aliceKey)[0].message)
        guard case .fundingRequired(_, _, let script) = try XCTUnwrap(events.first) else { throw LightningError.invalidState }
        let funding = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 1),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])], outputs: [.init(value: 100_000, scriptPubKey: script)], locktime: 0)
        try await alice.provideFunding(temporaryID: temporary, peer: bobKey, transaction: funding, output: 0)
        _ = try await bob.receive(peer: aliceKey, message: alice.pendingMessages(peer: bobKey)[0].message)
        _ = try await alice.receive(peer: bobKey, message: bob.pendingMessages(peer: aliceKey)[0].message)
        let channels = await alice.channels()
        let id = try XCTUnwrap(channels.first?.id)
        _ = try await alice.fundingConfirmed(channelID: id, peer: bobKey, transaction: funding, confirmations: 3)
        _ = try await bob.fundingConfirmed(channelID: id, peer: aliceKey, transaction: funding, confirmations: 3)
        let ar = try await alice.pendingMessages(peer: bobKey).first { $0.message.type == 36 }!.message
        let br = try await bob.pendingMessages(peer: aliceKey).first { $0.message.type == 36 }!.message
        _ = try await alice.receive(peer: bobKey, message: br)
        _ = try await bob.receive(peer: aliceKey, message: ar)
        try await alice.configureRecovery(channelID: id, peer: bobKey, destination: ChannelScripts.witnessKeyHash(aliceKey), feeSat: 500)
        try await bob.configureRecovery(channelID: id, peer: aliceKey, destination: ChannelScripts.witnessKeyHash(bobKey), feeSat: 500)
        return Pair(alice: alice, bob: bob, aliceKey: aliceKey, bobKey: bobKey, id: id, aliceStore: aStore, bobStore: bStore)
    }
    private func pump(_ sender: LightningEngine, peer: Data, to receiver: LightningEngine, from: Data,
                      sent: inout Set<UInt64>) async throws {
        for message in try await sender.pendingMessages(peer: peer) where !sent.contains(message.sequence) {
            _ = try await receiver.receive(peer: from, message: message.message)
            sent.insert(message.sequence)
        }
    }
    private func storedChannel(_ memory: JournalMemory) throws -> ChannelState {
        try XCTUnwrap(JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(memory.load())).channels.first)
    }
    func testHTLCCommitRevocationAndSettlementBalances() async throws {
        let p = try await pair()
        let invoice = try await p.bob.registerReceive(id: Data(repeating: 88, count: 32), amountMsat: 5_000_000, expiry: 200)
        let state = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(p.bobStore.load()))
        let preimage = try XCTUnwrap(state.incoming.first?.preimage)
        let request = LightningEngine.DirectPayment(id: Data(repeating: 89, count: 32), peer: p.bobKey, channelID: p.id,
            paymentHash: invoice.paymentHash, paymentSecret: invoice.paymentSecret, amountMsat: invoice.amountMsat, feeLimitMsat: 0, expiry: 200)
        let payment = try await p.alice.payDirect(request)
        let beforeRetry = p.aliceStore.load()
        let repeated = try await p.alice.payDirect(request)
        XCTAssertEqual(payment, repeated); XCTAssertEqual(beforeRetry, p.aliceStore.load())
        var aSent = Set<UInt64>(), bSent = Set<UInt64>()
        try await pump(p.alice, peer: p.bobKey, to: p.bob, from: p.aliceKey, sent: &aSent)
        do { try await p.bob.fulfillHTLC(channelID: p.id, peer: p.aliceKey, id: 0, preimage: preimage); XCTFail("No preimage before irrevocable addition") } catch {}
        try await pump(p.bob, peer: p.aliceKey, to: p.alice, from: p.bobKey, sent: &bSent)
        try await pump(p.alice, peer: p.bobKey, to: p.bob, from: p.aliceKey, sent: &aSent)
        let beforeInvalid = p.aliceStore.load()
        var invalid = LightningWire.Writer(); invalid.append(p.id); invalid.u64(0); invalid.append(Data(repeating: 42, count: 32))
        do { _ = try await p.alice.receive(peer: p.bobKey, message: .init(type: 130, payload: invalid.data)); XCTFail() } catch {}
        XCTAssertEqual(beforeInvalid, p.aliceStore.load())
        // Optional attribution (odd TLV 1) is sent by the independent LDK.
        // Its presence cannot invalidate a correctly authenticated preimage.
        for outbound in try await p.bob.pendingMessages(peer: p.aliceKey) where outbound.message.type == 130 {
            var extended = LightningWire.Writer(); extended.append(outbound.message.payload)
            try extended.tlvs([.init(type: 1, value: Data(repeating: 3, count: 1040))])
            _ = try await p.alice.receive(peer: p.bobKey, message: .init(type: 130, payload: extended.data))
            bSent.insert(outbound.sequence)
        }
        for _ in 0..<4 {
            try await pump(p.bob, peer: p.aliceKey, to: p.alice, from: p.bobKey, sent: &bSent)
            try await pump(p.alice, peer: p.bobKey, to: p.bob, from: p.aliceKey, sent: &aSent)
        }
        let paid = await p.alice.payments(), received = await p.bob.payments()
        XCTAssertEqual(paid.map(\.phase), [.settled]); XCTAssertEqual(received.map(\.phase), [.settled])
        XCTAssertEqual(paid.first?.preimage, preimage)
        let a = try storedChannel(p.aliceStore), b = try storedChannel(p.bobStore)
        XCTAssertEqual(a.localNumber, 2); XCTAssertEqual(a.remoteNumber, 2)
        XCTAssertEqual(b.localNumber, 2); XCTAssertEqual(b.remoteNumber, 2)
        XCTAssertTrue(a.updates.allSatisfy(\.irrevocable)); XCTAssertTrue(b.updates.allSatisfy(\.irrevocable))
        XCTAssertEqual(try a.view(localOwner: true, number: 2).localMsat, 95_000_000)
        XCTAssertEqual(try b.view(localOwner: true, number: 2).localMsat, 5_000_000)
        XCTAssertTrue(try a.view(localOwner: true, number: 2).htlcs.isEmpty)
        XCTAssertEqual(a.learnedPreimages, [preimage])
    }
}

extension ChannelEngineTests {
    func testOnionRejectionDoesNotInterruptChannelButPersistenceFailureDoes() async throws {
        let p = try await pair(holdingPeer: true), (request, invoice) = try offerPayment(p)
        _ = try await p.alice.payOffer(request, now: 100)
        let reply = try await p.alice.replyPath(purpose: 1, id: request.id, through: [])
        let stored = p.aliceStore.load()
        let unsupported = try OnionMessage.create(to: reply, content: .init(type: 68, value: Data()))
        let ignored = try await p.alice.receiveOnionMessage(unsupported, now: 101)
        XCTAssertTrue(ignored.isEmpty); XCTAssertEqual(stored, p.aliceStore.load())
        let malformed = try await p.alice.receiveOnionMessage(.init(type: 513, payload: Data([0])), now: 101)
        XCTAssertTrue(malformed.isEmpty); XCTAssertEqual(stored, p.aliceStore.load())
        let valid = try OnionMessage.create(to: reply, content: .init(type: 70, value: invoice.bytes))
        p.aliceStore.fail()
        do { _ = try await p.alice.receiveOnionMessage(valid, now: 102); XCTFail("Storage failure must never become a dropped message") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertEqual(stored, p.aliceStore.load())
        do { _ = try await p.alice.pendingMessages(peer: p.bobKey); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
    }
    func testReestablishmentAcceptsOnlyOriginalFundingIdentity() async throws {
        let p = try await pair(), channel = try storedChannel(p.aliceStore)
        let restored = try await engine(p.aliceStore, peer: p.bobKey)
        var base = LightningWire.Writer(); base.append(p.id); base.u64(1); base.u64(0)
        base.append(Data(repeating: 0, count: 32)); base.append(try key(2))
        let stored = p.aliceStore.load()
        for identity in [Data(repeating: 3, count: 32) + Data([0]), channel.fundingTxid! + Data([1]), channel.fundingTxid!] {
            var bad = LightningWire.Writer(); bad.append(base.data); try bad.tlvs([.init(type: 5, value: identity)])
            do { _ = try await restored.receive(peer: p.bobKey, message: .init(type: 136, payload: bad.data)); XCTFail() } catch {}
            XCTAssertEqual(stored, p.aliceStore.load())
        }
        var valid = LightningWire.Writer(); valid.append(base.data)
        try valid.tlvs([.init(type: 5, value: channel.fundingTxid! + Data([0]))])
        _ = try await restored.receive(peer: p.bobKey, message: .init(type: 136, payload: valid.data))
        let pending = try await restored.pendingMessages(peer: p.bobKey)
        XCTAssertFalse(pending.contains { $0.message.type == 136 })
    }
    private func offerPayment(_ pair: Pair, amount: UInt64 = 5_000_000, fee: UInt64 = 1000) throws -> (LightningEngine.OfferPayment, StaticInvoice) {
        let server = try OnionMessage.path(nodes: [key(9)], context: Data([1]), authenticationKey: Data(repeating: 22, count: 32))
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([.init(type: 2, value: chain),
            .init(type: 16, value: server.encoded()), .init(type: 22, value: key(11))]))
        let route = try AsyncPaymentRoute(holdingPeer: pair.bobKey, introduction: key(9), shortChannelID: 123,
                                         baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48)
        let invoice = try StaticInvoice(offer: offer, paymentPaths: [server],
            payInfo: [.init(baseMsat: 0, proportionalMillionths: 0, expiryDelta: 18, minimumMsat: 1, maximumMsat: 50_000_000, features: .init(bytes: Data()))],
            notificationPaths: [server], createdAt: 100, relativeExpiry: 3600, signingSecret: Data(repeating: 11, count: 32))
        return (LightningEngine.OfferPayment(id: Data(repeating: 99, count: 32), channelID: pair.id, offer: offer,
                    amountMsat: amount, feeLimitMsat: fee, maximumDelta: 144, route: route), invoice)
    }
    func testOfferPaymentIDAndRequestSurviveRestartWithoutAnotherHTLC() async throws {
        let p = try await pair(holdingPeer: true), (request, invoice) = try offerPayment(p)
        let initial = try await p.alice.payOffer(request, now: 100), stored = p.aliceStore.load()
        XCTAssertEqual(initial.phase, .preparing)
        let retry = try await p.alice.payOffer(request, now: 101)
        XCTAssertEqual(retry, initial); XCTAssertEqual(stored, p.aliceStore.load())
        let (different, _) = try offerPayment(p, amount: 6_000_000)
        do { _ = try await p.alice.payOffer(different, now: 101); XCTFail() } catch {}
        XCTAssertEqual(stored, p.aliceStore.load())
        let outbound = try await p.alice.pendingOnionMessages(peer: p.bobKey, now: 101)
        XCTAssertEqual(outbound.count, 1)
        let response = LightningWire.TLV(type: 70, value: invoice.bytes)
        _ = try await p.alice.acceptStaticInvoice(response, id: request.id, now: 102)
        let afterInvoice = p.aliceStore.load()
        _ = try await p.alice.acceptStaticInvoice(response, id: request.id, now: 103)
        XCTAssertEqual(afterInvoice, p.aliceStore.load())
        let state = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(afterInvoice))
        XCTAssertEqual(state.channels[0].nextLocalHTLC, 1)
        XCTAssertEqual(state.payments[0].payment.phase, .inFlight)
        let update = try XCTUnwrap(state.outbox.first { $0.message.type == 128 })
        var reader = LightningWire.Reader(update.message.payload)
        _ = try reader.take(32 + 8 + 8 + 32 + 4 + 1366)
        XCTAssertEqual(try reader.tlvs(known: [75537]), [.init(type: 75537, value: Data())])
        let restored = try LightningEngine(chain: chain, journal: MemoryJournal(p.aliceStore))
        let history = await restored.payments()
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].hash, initial.hash)
        do { _ = try await restored.payOffer(request, now: 104); XCTFail("No send before chain catch-up") } catch {}
    }
    func testExpiredInvoiceCannotSendAndFailedPersistenceFreezesAsyncOutbox() async throws {
        let p = try await pair(holdingPeer: true), (request, invoice) = try offerPayment(p)
        _ = try await p.alice.payOffer(request, now: 100)
        let saved = p.aliceStore.load()
        do { _ = try await p.alice.acceptStaticInvoice(.init(type: 70, value: invoice.bytes), id: request.id, now: 401); XCTFail() } catch {}
        XCTAssertEqual(saved, p.aliceStore.load())
        _ = try await p.alice.expireInvoiceRequests(now: 401)
        let history = await p.alice.payments()
        XCTAssertEqual(history.map(\.phase), [.failed])
        let state = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(p.aliceStore.load()))
        XCTAssertEqual(state.channels[0].nextLocalHTLC, 0)
        XCTAssertTrue(state.async.outbox.isEmpty)
        let q = try await pair(holdingPeer: true), (other, _) = try offerPayment(q)
        q.aliceStore.fail()
        do { _ = try await q.alice.payOffer(other, now: 100); XCTFail() } catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        do { _ = try await q.alice.pendingOnionMessages(peer: q.bobKey, now: 100); XCTFail() } catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
    }
    func testAsyncRequiresHoldingPeerAndFeeAuthorization() async throws {
        let p = try await pair(), (request, _) = try offerPayment(p)
        let before = p.aliceStore.load()
        do { _ = try await p.alice.payOffer(request, now: 100); XCTFail() } catch {}
        XCTAssertEqual(before, p.aliceStore.load())
        let q = try await pair(holdingPeer: true), (underBudget, invoice) = try offerPayment(q, fee: 999)
        _ = try await q.alice.payOffer(underBudget, now: 100)
        let saved = q.aliceStore.load()
        do { _ = try await q.alice.acceptStaticInvoice(.init(type: 70, value: invoice.bytes), id: underBudget.id, now: 101); XCTFail() } catch {}
        XCTAssertEqual(saved, q.aliceStore.load())
    }
}
