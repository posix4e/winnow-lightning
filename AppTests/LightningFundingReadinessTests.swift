@testable import WinnowApp
import Foundation
import LightningCore
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningFundingReadinessTests: XCTestCase {
    private final class Journal: LightningJournal {
        var bytes: Data?
        func load() throws -> Data? { bytes }
        func store(_ snapshot: Data) throws { bytes = snapshot }
    }
    private final class Approved: DeviceAuthenticating {
        var entered: (() -> Void)?
        func authenticate(reason: String) async throws { entered?() }
    }
    private struct Fixture {
        let model: AppModel
        let controller: LightningAppController
        let engine: LightningEngine
        let wallet: Wallet
        let pool: PeerPool
        let node: LoopbackNode
        let peer: Data
        let review: LightningAppController.FundingReview
        let authenticator: Approved
    }

    private func makeFixture() async throws -> Fixture {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "funding-readiness-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_DEVICE_AUTH": "1"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, value in value })
        else { throw WalletError.invalidBundle("isolated Debug test namespace unavailable") }
        addTeardownBlock { cleanup.wipeIfRequested() }
        let authenticator = Approved(), keys = InMemoryStoreKeyVault(), spendingKeys = InMemoryKeyStore()
        let model = AppModel(deviceAuthenticator: authenticator, e2e: mode, defaults: makeDefaults(),
            storeKeys: keys, keyStore: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        _ = await model.vaultStore.configure(storageURL: nil, network: .regtest)
        let wallet = try makeTestWallet(network: .regtest, storageURL: root.appending(path: "wallet.json"),
            keyStore: spendingKeys, creationHeight: 0)
        // Wallet.apply consumes a trusted BlockMatch in these unit fixtures;
        // use a non-coinbase coin so this tests funding rather than maturity.
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let incoming = Transaction(version: 2,
            inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 0), scriptSig: Data(), sequence: 0xFFFF_FFFF)],
            outputs: [.init(value: 500_000, scriptPubKey: script)], locktime: 0)
        try await wallet.apply(match: fakeMatch(height: 1, transactions: [incoming]))
        let node = LoopbackNode(params: .regtest, withholdHeaders: true)
        try await node.start()
        let pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [await node.endpoint])
        let chain = try HeaderChain(params: .regtest)
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: nil)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: nil)
        addTeardownBlock { await pool.stop(); await node.stop(); await broadcaster.shutdown() }
        await pool.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await pool.connectedPeers().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let connected = await pool.connectedPeers()
        XCTAssertEqual(connected.count, 1, "loopback handshake is a fixture precondition")
        _ = try XCTUnwrap(connected.first)
        await model.installForTesting(wallet: wallet, stack: .init(pool: pool, chain: chain, filters: filters, broadcaster: broadcaster))
        let controller = try XCTUnwrap(model.lightning)
        try await controller.prepare(directory: root, headers: chain)
        let engine = try XCTUnwrap(controller.engine)
        let counterparty = try LightningEngine(chain: NetworkParams.regtest.genesisHash,
            nodeSecret: Data(repeating: 21, count: 32), journal: Journal())
        let peer = try await counterparty.nodeID(), local = try await engine.nodeID()
        try await engine.chainCaughtUp(); try await counterparty.chainCaughtUp()
        try await engine.peerInitialized(peer, features: .channelOpening)
        try await counterparty.peerInitialized(local, features: .channelOpening)
        _ = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 5_000)
        let openingMessages = try await engine.pendingMessages(peer: peer)
        let open = try XCTUnwrap(openingMessages.first(where: { $0.message.type == 32 })).message
        _ = try await counterparty.receive(peer: local, message: open)
        let acceptingMessages = try await counterparty.pendingMessages(peer: local)
        let accept = try XCTUnwrap(acceptingMessages.first(where: { $0.message.type == 33 })).message
        _ = try await engine.receive(peer: peer, message: accept)
        let fundingRequests = try await engine.fundingRequests()
        let request = try XCTUnwrap(fundingRequests.first)
        let review = try await controller.reviewFunding(request, model: model)
        return Fixture(model: model, controller: controller, engine: engine, wallet: wallet,
            pool: pool, node: node, peer: peer, review: review, authenticator: authenticator)
    }

    /// The real model/driver clears engine readiness and blocks on the peer's
    /// getheaders response. No test setter fabricates a syncing boolean.
    private func holdScan(_ fixture: Fixture) async throws -> Task<Void, Never> {
        let scan = Task { await fixture.model.syncNow() }
        let request = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(request, "the verified scan must reach its held header request")
        XCTAssertTrue(fixture.model.status.syncing)
        let current = await fixture.engine.isChainCurrent()
        XCTAssertFalse(current)
        return scan
    }
    private func releaseScan(_ fixture: Fixture, scan: Task<Void, Never>) async throws {
        try await fixture.node.send(.headers([]))
        let second = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(second, "both the driver and filter scan must verify headers")
        try await fixture.node.send(.headers([]))
        await scan.value
        XCTAssertFalse(fixture.model.status.syncing)
        XCTAssertNil(fixture.model.status.lastSyncError)
        let current = await fixture.engine.isChainCurrent()
        XCTAssertTrue(current)
    }
    private func startFunding(_ fixture: Fixture) async -> Task<Void, Error> {
        let entered = expectation(description: "actual funding authentication entered")
        fixture.authenticator.entered = { entered.fulfill() }
        let operation = Task { try await fixture.controller.fund(fixture.review, model: fixture.model) }
        await fulfillment(of: [entered], timeout: 5)
        return operation
    }
    private func assertUnreserved(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        let reservations = await fixture.wallet.fundingReservations
        let changeIndex = await fixture.wallet.nextChangeIndex
        let pending = await fixture.wallet.history.filter { $0.height == 0 }
        XCTAssertTrue(reservations.isEmpty, file: file, line: line)
        XCTAssertEqual(changeIndex, 0, file: file, line: line)
        XCTAssertTrue(pending.isEmpty, file: file, line: line)
    }
    private func assertReadinessRejected(_ operation: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation.value; XCTFail("funding passed an unverified readiness gate", file: file, line: line) }
        catch { XCTAssertEqual(error as? LightningError, .invalidState, file: file, line: line) }
    }

    func testApprovalWaitsForTheActualScanThenSignsTheReviewedFundingOnce() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
        try await releaseScan(fixture, scan: scan)
        try await operation.value
        let reservations = await fixture.wallet.fundingReservations
        XCTAssertEqual(reservations.count, 1)
        let reserved = try XCTUnwrap(reservations.first)
        XCTAssertEqual(reserved.phase, .submitted)
        XCTAssertTrue(try fixture.review.preview.authorizes(transaction: reserved.transaction(), fee: reserved.fee,
            changeAmount: reserved.changeOutput()?.value))
        let fundedPhase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(fundedPhase, .awaitingFundingSignature)
        let outbox = try await fixture.engine.pendingMessages(peer: fixture.peer)
        XCTAssertEqual(outbox.filter { $0.message.type == 34 }.count, 1)
        XCTAssertFalse(fixture.model.keychainAuthentication.isGranted)
        let reopened = try Wallet.open(storageURL: XCTUnwrap(fixture.model.storageDirectory()).appending(path: "wallet.json"), keyStore: fixture.model.keyStore)
        let reopenedReservations = await reopened.fundingReservations
        XCTAssertEqual(reopenedReservations, reservations, "exact signed reservation must survive reopening")
    }

    func testCancelledApprovalDuringHeldScanCannotReserveInputs() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        operation.cancel()
        do { try await operation.value; XCTFail("cancelled approval funded") } catch is CancellationError {}
        await assertUnreserved(fixture)
        try await releaseScan(fixture, scan: scan)
        XCTAssertFalse(fixture.model.keychainAuthentication.isGranted)
    }

    func testFailedScanCannotReserveInputs() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.pool.stop()
        await scan.value
        XCTAssertFalse(fixture.model.status.syncing)
        XCTAssertNotNil(fixture.model.status.lastSyncError)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
    }

    func testIncompleteChainWithNoActiveScanRejectsWithoutStartingOne() async throws {
        let fixture = try await makeFixture()
        await fixture.engine.chainDisconnected()
        XCTAssertFalse(fixture.model.status.syncing)
        let operation = await startFunding(fixture)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
        let requests = await fixture.node.receivedMessages.filter { $0.command == "getheaders" }
        XCTAssertTrue(requests.isEmpty, "funding must not initiate an unrequested scan")
    }

    func testPeerDisconnectedDuringScanCannotReserveInputsEvenAfterVerifiedCompletion() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.engine.peerDisconnected(fixture.peer)
        try await releaseScan(fixture, scan: scan)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
    }

    func testNetworkGenerationChangeDuringScanCancelsBeforeReservation() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.controller.stop()
        do { try await operation.value; XCTFail("stale generation funded") } catch is CancellationError {}
        await assertUnreserved(fixture)
        // The old scan may finish its verified reads, but its generation check
        // must reject publication through the stopped controller.
        try await fixture.node.send(.headers([]))
        let request = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(request)
        try await fixture.node.send(.headers([]))
        await scan.value
        XCTAssertNotNil(fixture.model.status.lastSyncError)
    }

    func testStalledActiveScanExpiresWithoutReservationOrFinancialRetry() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let start = ContinuousClock.now
        let operation = await startFunding(fixture)
        await assertReadinessRejected(operation)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(12))
        XCTAssertTrue(fixture.model.status.syncing, "approval's deadline must not pretend the scan completed")
        await assertUnreserved(fixture)
        try await releaseScan(fixture, scan: scan)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
    }
}
