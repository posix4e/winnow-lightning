import Foundation
import XCTest
import TestSupport
@testable import WalletCore
@testable import LightningCore

private final class RecoveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var failWrites = false
    func load() -> Data? { lock.withLock { bytes } }
    func fail() { lock.withLock { failWrites = true } }
    func store(_ value: Data) throws {
        try lock.withLock { if failWrites { throw LightningError.storageFailed }; bytes = value }
    }
}
private final class RecoveryJournal: LightningJournal {
    let store: RecoveryStore
    init(_ store: RecoveryStore) { self.store = store }
    func load() -> Data? { store.load() }
    func store(_ data: Data) throws { try store.store(data) }
}

final class ChainRecoveryTests: XCTestCase, @unchecked Sendable {
    private let genesis = makeSyntheticChain(length: 0).blocks[0].header
    private func fixture() throws -> (ChannelState, Transaction) {
        let alice = try ChannelSecrets(), bob = try ChannelSecrets()
        var channel = try ChannelState(peer: ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32)),
            temporaryID: Data(repeating: 3, count: 32), capacity: 100_000, pushMsat: 0, feePerKW: 1000, isFunder: true,
            secrets: alice, local: alice.terms(capacity: 100_000), remote: bob.terms(capacity: 100_000), phase: .ready)
        let funding = try Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 0),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])],
            outputs: [.init(value: 100_000, scriptPubKey: channel.fundingScript())], locktime: 0)
        channel.fundingTxid = funding.txid; channel.fundingOutput = 0
        channel.fundingTransaction = funding.serialized(includeWitness: true)
        channel.localReady = true; channel.remoteReady = true; channel.fundingIsConfirmed = true
        channel.remoteNextPoint = try bob.point(1)
        let commitment = try channel.commitment(localOwner: true), digest = try ChannelTransactions.fundingDigest(commitment)
        channel.signedCommitment = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: digest, secret: alice.funding),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: bob.funding)).serialized(includeWitness: true)
        channel.recovery = .init(destination: Data([0, 20]) + Data(repeating: 12, count: 20), feeSat: 500)
        return (channel, funding)
    }
    private func engine(channel: ChannelState? = nil, store: RecoveryStore) throws -> LightningEngine {
        var state = LightningEngine.State(chain: genesis.hash, nodeSecret: Data(repeating: 1, count: 32))
        if let channel { state.channels = [channel] }
        try store.store(JSONEncoder().encode(state))
        return try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
    }
    @discardableResult
    private func scan(_ engine: LightningEngine, height: UInt32, previous: Data, transaction: Transaction? = nil) async throws -> BlockHeader {
        let root = transaction?.txid ?? Data(repeating: UInt8(truncatingIfNeeded: height), count: 32)
        let header = minedHeader(previousHash: previous, merkleRoot: root, time: genesis.time + height * 600)
        let block = transaction.map { Block(header: header, transactions: [$0]) }
        _ = try await engine.scannedBlock(.init(height: height, header: header, block: block, watchRevision: engine.chainStatus().revision))
        return header
    }
    private func state(_ store: RecoveryStore) throws -> LightningEngine.State {
        try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(store.load()))
    }
    private func paymentFixture(preimage: Data, success: Bool) throws -> (ChannelState, Transaction, Transaction) {
        var (channel, _) = try fixture()
        let bob = try ChannelSecrets()
        channel.remote = try bob.terms(capacity: channel.capacity)
        let funding = try Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 0),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])],
            outputs: [.init(value: 100_000, scriptPubKey: channel.fundingScript())], locktime: 0)
        channel.fundingTxid = funding.txid
        channel.fundingTransaction = funding.serialized(includeWitness: true)
        channel.localNumber = 1; channel.remoteNumber = 1
        channel.remoteCurrentPoint = try bob.point(1); channel.remoteNextPoint = try bob.point(2)
        let htlc = ChannelTransactions.HTLC(id: 0, offered: true, amountMsat: 5_000_000,
                                           paymentHash: ChannelKeys.hash(preimage), expiry: 12)
        channel.updates = [.init(change: .add(htlc, onion: Data()), fromLocal: true,
                                 localNumber: 1, remoteNumber: 1, remoteAcknowledged: true)]
        let commitment = try channel.commitment(localOwner: true), point = try channel.secrets.point(1)
        let digest = try ChannelTransactions.fundingDigest(commitment)
        channel.signedCommitment = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: digest, secret: channel.secrets.funding),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: bob.funding)).serialized(includeWitness: true)
        let output = try XCTUnwrap(commitment.htlcOutputs.first)
        let remoteKey = try ChannelKeys.derivedPrivateKey(baseSecret: bob.htlc, commitmentPoint: point)
        let remoteSignature = try ChannelKeys.sign(digest: ChannelRecovery.htlcDigest(commitment: commitment, output: output), secret: remoteKey)
        channel.localHTLCSignatures = [remoteSignature]
        let spend: Transaction
        if success {
            spend = try ChannelRecovery.remoteHTLC(commitment: commitment, output: output,
                destination: channel.recovery!.script, feeSat: 500, htlcSecret: remoteKey, preimage: preimage)
        } else {
            let localKey = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.htlc, commitmentPoint: point)
            let signature = try ChannelKeys.sign(digest: ChannelRecovery.htlcDigest(commitment: commitment, output: output), secret: localKey)
            spend = try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
                localSignature: signature, remoteSignature: remoteSignature, preimage: nil)
        }
        return (channel, funding, spend)
    }
    func testCooperativeCloseFinalizesAtDepthAndReorgRestoresClosing() async throws {
        var (channel, funding) = try fixture()
        channel.localShutdown = Data([0x51, 32]) + Data(repeating: 7, count: 32)
        channel.remoteShutdown = Data([0, 20]) + Data(repeating: 8, count: 20)
        channel.closingFee = 500; channel.closingFeeLimit = 724
        let close = try channel.closeTransaction(fee: 500)
        channel.closingTransaction = close.serialized(includeWitness: true)
        channel.phase = .closing
        let store = RecoveryStore(), engine = try engine(channel: channel, store: store)
        let first = try await scan(engine, height: 1, previous: genesis.hash, transaction: funding)
        let second = try await scan(engine, height: 2, previous: first.hash, transaction: close)
        var tip = second
        for height in UInt32(3)...6 { tip = try await scan(engine, height: height, previous: tip.hash) }
        let before = await engine.channels()
        XCTAssertEqual(before.first?.phase, .closing)
        _ = try await scan(engine, height: 7, previous: tip.hash)
        let finalized = await engine.channels()
        XCTAssertEqual(finalized.first?.phase, .closed)
        try await engine.blocksDisconnected(to: 6, hash: tip.hash)
        let reverted = await engine.channels()
        XCTAssertEqual(reverted.first?.phase, .closing)
        _ = try await scan(engine, height: 7, previous: tip.hash)
        let reconfirmed = await engine.channels()
        XCTAssertEqual(reconfirmed.first?.phase, .closed)
    }

    func testOnChainSuccessAndTimeoutReconcileOnceAfterDepthAndUndoOnReorg() async throws {
        for success in [false, true] {
            let preimage = Data(repeating: 23, count: 32), store = RecoveryStore()
            let (channel, funding, spend) = try paymentFixture(preimage: preimage, success: success)
            var snapshot = LightningEngine.State(chain: genesis.hash, nodeSecret: Data(repeating: 1, count: 32))
            snapshot.channels = [channel]
            snapshot.payments = [.init(payment: .init(id: Data(repeating: 4, count: 32), hash: ChannelKeys.hash(preimage),
                amountMsat: 5_000_000, incoming: false, phase: .awaitingRecipient), channelID: channel.id, htlcID: 0, request: nil)]
            try store.store(JSONEncoder().encode(snapshot))
            let engine = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
            let first = try await scan(engine, height: 1, previous: genesis.hash, transaction: funding)
            var header = try await scan(engine, height: 2, previous: first.hash,
                                        transaction: Transaction.decode(XCTUnwrap(channel.signedCommitment)))
            XCTAssertEqual(try state(store).payments[0].payment.phase, .recovering)
            for height: UInt32 in 3...12 { header = try await scan(engine, height: height, previous: header.hash) }
            header = try await scan(engine, height: 13, previous: header.hash, transaction: spend)
            for height: UInt32 in 14...17 { header = try await scan(engine, height: height, previous: header.hash) }
            XCTAssertEqual(try state(store).payments[0].payment.phase, .recovering)
            header = try await scan(engine, height: 18, previous: header.hash)
            XCTAssertEqual(try state(store).payments[0].payment.phase, success ? .settled : .failed)
            XCTAssertEqual(try state(store).payments[0].chainResolution?.transactionID, spend.txid)
            let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
            _ = try await scan(restored, height: 19, previous: header.hash)
            XCTAssertEqual(try state(store).payments.count, 1)
            try await restored.blocksDisconnected(to: 17, hash: state(store).scan.positions.first { $0.height == 17 }!.hash)
            XCTAssertEqual(try state(store).payments[0].payment.phase, .recovering)
            XCTAssertNil(try state(store).payments[0].chainResolution)
            if success { XCTAssertTrue(try state(store).channels[0].learnedPreimages.contains(preimage)) }
            try await restored.blocksDisconnected(to: 1, hash: first.hash)
            XCTAssertEqual(try state(store).payments[0].payment.phase, .recovering)
            XCTAssertNil(try state(store).channels[0].observedFundingSpend)
        }
    }
    func testRejectsWrongAncestryStaleWatchesAndIncompleteScan() async throws {
        let store = RecoveryStore(), engine = try engine(store: store)
        let before = store.load()
        let wrong = minedHeader(previousHash: Data(repeating: 6, count: 32), merkleRoot: genesis.hash, time: genesis.time + 600)
        do { _ = try await engine.scannedBlock(.init(height: 1, header: wrong, block: nil, watchRevision: 0)); XCTFail() }
        catch { XCTAssertEqual(error as? LightningChainError, .recoveryRequired) }
        XCTAssertEqual(before, store.load())
        let first = try await scan(engine, height: 1, previous: genesis.hash)
        do { _ = try await engine.scannedBlock(.init(height: 2, header: first, block: nil, watchRevision: 0)); XCTFail() }
        catch { XCTAssertEqual(error as? LightningChainError, .changedWatches) }
        do { _ = try await engine.pendingRecoveryBroadcasts(); XCTFail("A scan callback alone does not authorize operation") } catch {}
        let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
        let status = await restored.chainStatus()
        XCTAssertEqual(status.nextHeight, 2); XCTAssertEqual(status.positions.last?.hash, first.hash)
        do { _ = try await restored.pendingRecoveryBroadcasts(); XCTFail("Restart must catch up") } catch {}
    }
    func testFundingReorgBlocksOldOutboxAndPaymentUntilReconfirmed() async throws {
        var (channel, funding) = try fixture()
        var ready = LightningWire.Writer(); ready.append(channel.id); ready.append(try channel.secrets.point(1))
        let store = RecoveryStore(), engine = try engine(channel: channel, store: store)
        let first = try await scan(engine, height: 1, previous: genesis.hash, transaction: funding)
        let second = try await scan(engine, height: 2, previous: first.hash)
        _ = try await scan(engine, height: 3, previous: second.hash)
        try await engine.chainCaughtUp(height: 3)
        var snapshot = try state(store)
        snapshot.outbox = [try .init(sequence: 0, peer: channel.peer, channelID: channel.id, message: .init(type: 36, payload: ready.data))]
        snapshot.nextSequence = 1
        try store.store(JSONEncoder().encode(snapshot))
        let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
        try await restored.blocksDisconnected(to: 1, hash: first.hash)
        channel = try XCTUnwrap(state(store).channels.first)
        XCTAssertFalse(channel.fundingIsConfirmed)
        try await restored.chainCaughtUp(height: 1)
        try await restored.peerInitialized(channel.peer, features: .channelOpening)
        let pending = try await restored.pendingMessages(peer: channel.peer)
        XCTAssertEqual(pending.map(\.message.type), [136])
        let request = LightningEngine.DirectPayment(id: Data(repeating: 1, count: 32), peer: channel.peer, channelID: channel.id,
            paymentHash: Data(repeating: 2, count: 32), paymentSecret: Data(repeating: 3, count: 32), amountMsat: 1_000_000, feeLimitMsat: 0, expiry: 200)
        do { _ = try await restored.payDirect(request); XCTFail() } catch {}
        let replacement = try await scan(restored, height: 2, previous: first.hash)
        _ = try await scan(restored, height: 3, previous: replacement.hash)
        XCTAssertTrue(try XCTUnwrap(state(store).channels.first).fundingIsConfirmed)
    }
    func testForceCloseIntentSurvivesCrashButStaleBackupCannotPublish() async throws {
        let (channel, _) = try fixture(), store = RecoveryStore()
        let engine = try engine(channel: channel, store: store)
        try await engine.chainCaughtUp(height: 3)
        guard case .broadcastClose(_, let raw) = try await engine.forceClose(channelID: channel.id, peer: channel.peer) else { return XCTFail() }
        XCTAssertEqual(raw, channel.signedCommitment)
        let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
        try await restored.chainCaughtUp(height: 3)
        let events = try await restored.pendingCloseBroadcasts()
        guard case .broadcastClose(_, let saved) = try XCTUnwrap(events.first) else { return XCTFail() }
        XCTAssertEqual(raw, saved)
        var stale = channel; stale.dataLossDetected = true; stale.phase = .recovering
        let recovery = try self.engine(channel: stale, store: RecoveryStore())
        try await recovery.chainCaughtUp(height: 3)
        do { _ = try await recovery.forceClose(channelID: channel.id, peer: channel.peer); XCTFail() } catch {}
        let channels = await recovery.channels(); XCTAssertNil(channels.first?.signedCommitment)
        let failedStore = RecoveryStore(), failed = try self.engine(channel: channel, store: failedStore)
        try await failed.chainCaughtUp(height: 3); failedStore.fail()
        do { _ = try await failed.forceClose(channelID: channel.id, peer: channel.peer); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        do { _ = try await failed.pendingCloseBroadcasts(); XCTFail() } catch {}
    }
    func testDelayedSweepUsesNewConfirmationHeightAfterReorg() async throws {
        let (channel, funding) = try fixture(), store = RecoveryStore()
        let engine = try engine(channel: channel, store: store)
        let first = try await scan(engine, height: 1, previous: genesis.hash, transaction: funding)
        let commitment = try Transaction.decode(XCTUnwrap(channel.signedCommitment))
        var header = try await scan(engine, height: 2, previous: first.hash, transaction: commitment)
        XCTAssertEqual(try state(store).channels.first?.resolutions.count, 1)
        let delay = try XCTUnwrap(channel.remote?.delay)
        for height in 3...UInt32(delay) { header = try await scan(engine, height: height, previous: header.hash) }
        try await engine.chainCaughtUp(height: UInt32(delay))
        let immature = try await engine.pendingRecoveryBroadcasts(); XCTAssertTrue(immature.isEmpty)
        _ = try await scan(engine, height: UInt32(delay) + 1, previous: header.hash)
        try await engine.chainCaughtUp(height: UInt32(delay) + 1)
        let matured = try await engine.pendingRecoveryBroadcasts(); XCTAssertEqual(matured.count, 1)
        let saved = try XCTUnwrap(state(store).channels.first?.resolutions.first?.transaction)
        try await engine.blocksDisconnected(to: 1, hash: first.hash)
        try await engine.chainCaughtUp(height: 1)
        let disconnected = try await engine.pendingRecoveryBroadcasts(); XCTAssertTrue(disconnected.isEmpty)
        header = try await scan(engine, height: 2, previous: first.hash)
        _ = try await scan(engine, height: 3, previous: header.hash, transaction: commitment)
        try await engine.chainCaughtUp(height: 3)
        let reconfirmed = try await engine.pendingRecoveryBroadcasts(); XCTAssertTrue(reconfirmed.isEmpty)
        XCTAssertEqual(try state(store).channels.first?.resolutions.first?.transaction, saved)
        XCTAssertEqual(try state(store).channels.first?.phase, .closing)
    }
    func testScanBirthdaySurvivesRestartAndCannotSkipExistingChannels() async throws {
        let store = RecoveryStore(), engine = try engine(store: store)
        let birthday = minedHeader(previousHash: genesis.hash, merkleRoot: Data(repeating: 4, count: 32), time: genesis.time + 600)
        try await engine.startChainScan(height: 900_000, hash: birthday.hash)
        var saved = try state(store)
        saved.channels = [try fixture().0]
        try store.store(JSONEncoder().encode(saved))
        let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
        let status = await restored.chainStatus()
        XCTAssertEqual(status.origin.height, 900_000)
        XCTAssertEqual(status.origin.hash, birthday.hash)
        XCTAssertEqual(status.nextHeight, 900_001)
        do { try await restored.startChainScan(height: 900_100, hash: birthday.hash); XCTFail("skipped live channel history") }
        catch { XCTAssertEqual(error as? LightningError, .invalidState) }
        let first = try await scan(restored, height: 900_001, previous: birthday.hash)
        _ = try await scan(restored, height: 900_002, previous: first.hash)
        try await restored.blocksDisconnected(to: 900_000, hash: birthday.hash)
        _ = try await scan(restored, height: 900_001, previous: birthday.hash)
        do { try await restored.blocksDisconnected(to: 0, hash: genesis.hash); XCTFail("rewound below verified birthday") }
        catch { XCTAssertEqual(error as? LightningChainError, .recoveryRequired) }
    }

    func testLegacyJournalRetainsGenesisAndUpgradesWithoutLosingIdentity() async throws {
        let store = RecoveryStore()
        var legacy = LightningEngine.State(chain: genesis.hash, nodeSecret: Data(repeating: 1, count: 32))
        legacy.version = 2
        legacy.channels = [try fixture().0]
        try store.store(JSONEncoder().encode(legacy))
        let restored = try LightningEngine(chain: genesis.hash, journal: RecoveryJournal(store))
        try await restored.persistIdentity()
        let status = await restored.chainStatus()
        XCTAssertEqual(status.origin.height, 0)
        XCTAssertEqual(status.origin.hash, genesis.hash)
        XCTAssertEqual(try state(store).version, 3)
        XCTAssertEqual(try state(store).channels.first?.id, legacy.channels.first?.id)
        XCTAssertEqual(try state(store).nodeSecret, legacy.nodeSecret)
    }

    func testCheckpointWalletAndLightningScanWithoutGenesisHeaders() async throws {
        let fixture = makeSyntheticChain(length: 6), p = fixture.params
        let params = NetworkParams(network: p.network, magic: p.magic, defaultPort: p.defaultPort,
            genesisTime: p.genesisTime, genesisBits: p.genesisBits, genesisNonce: p.genesisNonce,
            genesisMerkleRoot: p.genesisMerkleRoot, genesisHash: p.genesisHash, powLimit: p.powLimit, dnsSeeds: [],
            checkpoint: .init(height: 4, header: fixture.blocks[4].header.serialized, chainwork: UInt256(10).bigEndianData))
        let node = LoopbackNode(params: params, chain: fixture.blocks)
        try await node.start()
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        defer { Task { await pool.stop(); await node.stop() } }
        await pool.start()
        let headers = try HeaderChain(params: params, start: .checkpoint)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 5, requiredCheckpointPeers: 1)
        let store = RecoveryStore(), engine = try engine(store: store)
        let driver = LightningChainDriver(engine: engine, headers: headers)
        let complete = try await driver.sync(using: filters, walletScripts: [], onEvent: { _ in }, onMatch: { _ in })
        XCTAssertTrue(complete)
        let missing = await headers.blockHash(at: 0), origin = await engine.chainStatus().origin
        XCTAssertNil(missing)
        XCTAssertEqual(origin.height, 4)
        XCTAssertEqual(origin.hash, fixture.blocks[4].hash)
        var saved = try state(store)
        saved.channels = [try self.fixture().0]
        saved.scan.rescanRequired = true
        try store.store(JSONEncoder().encode(saved))
        let reopened = try LightningEngine(chain: p.genesisHash, journal: RecoveryJournal(store))
        let rebuiltHeaders = try HeaderChain(params: params, start: .checkpoint)
        let rebuiltFilters = try FilterSync(pool: pool, chain: rebuiltHeaders, startHeight: 5, requiredCheckpointPeers: 1)
        let replay = LightningChainDriver(engine: reopened, headers: rebuiltHeaders)
        let replayed = try await replay.sync(using: rebuiltFilters, walletScripts: [], onEvent: { _ in }, onMatch: { _ in })
        XCTAssertTrue(replayed, "funding replay must use the saved birthday, not request absent genesis headers")
        let floor = await reopened.chainStatus().origin.height
        XCTAssertEqual(floor, 4)
    }

    func testDriverSharesVerifiedFilterScannerAndRestoresItsOwnFrontier() async throws {
        let fixture = makeSyntheticChain(length: 6)
        let node = LoopbackNode(params: fixture.params, chain: fixture.blocks, reverseFilters: true)
        try await node.start()
        let pool = PeerPool(params: fixture.params, peerCount: 1, manualPeers: [await node.endpoint])
        defer { Task { await pool.stop(); await node.stop() } }
        await pool.start()
        let headers = try HeaderChain(params: fixture.params)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let store = RecoveryStore(), engine = try engine(channel: self.fixture().0, store: store)
        let driver = LightningChainDriver(engine: engine, headers: headers)
        let complete = try await driver.sync(using: filters, walletScripts: [], onEvent: { _ in }, onMatch: { _ in })
        XCTAssertTrue(complete)
        let status = await engine.chainStatus(); XCTAssertEqual(status.nextHeight, 7)
        let allowed = try await engine.pendingRecoveryBroadcasts(); XCTAssertTrue(allowed.isEmpty)
        // A failed/stale consumer can lag the shared scanner. Restore only its
        // journal cursor and require the same scanner to replay that interval.
        try await engine.blocksDisconnected(to: 3, hash: fixture.blocks[3].hash)
        let replayed = try await driver.sync(using: filters, walletScripts: [], onEvent: { _ in }, onMatch: { _ in })
        XCTAssertTrue(replayed)
        let replayStatus = await engine.chainStatus(); XCTAssertEqual(replayStatus.nextHeight, 7)
    }
}
