@testable import WinnowApp
import CryptoKit
import LightningCore
import Security
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningAppTests: XCTestCase {
    private final class Denied: DeviceAuthenticating {
        var attempts = 0
        func authenticate(reason: String) async throws { attempts += 1; throw CancellationError() }
    }
    private final class Pending: DeviceAuthenticating {
        var entered: (() -> Void)?
        var continuation: CheckedContinuation<Void, any Error>?
        func authenticate(reason: String) async throws {
            try await withCheckedThrowingContinuation { continuation = $0; entered?() }
        }
    }
    private func key(_ seed: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: seed, count: 32)) }
    private func profile() throws -> LightningProfile {
        try LightningProfile(network: "regtest", name: "Fixture", peer: key(21).hex, host: "127.0.0.1", port: 1,
            route: .init(introduction: key(22).hex, shortChannelID: 1, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48), receive: nil)
    }
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lightning-app-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func prepared(_ dir: URL, keys: InMemoryStoreKeyVault = .init()) async throws -> LightningAppController {
        let controller = LightningAppController(keys: keys)
        try await controller.prepare(directory: dir, headers: HeaderChain(params: .regtest))
        return controller
    }
    private func review(_ profile: LightningProfile) throws -> LightningAppController.PaymentReview {
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([
            .init(type: 2, value: NetworkParams.regtest.genesisHash), .init(type: 22, value: key(23))]))
        let request = try LightningEngine.OfferPayment(id: Data(repeating: 1, count: 32), channelID: Data(repeating: 2, count: 32),
            offer: offer, amountMsat: 5000, feeLimitMsat: 1000, route: XCTUnwrap(profile.paymentRoute()))
        return .init(request: request, profile: profile, offerText: offer.string)
    }
    func testCancelledProviderReviewLeavesNoProfileOrJournalMutation() async throws {
        let dir = directory(), controller = try await prepared(dir), auth = Denied()
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { try await controller.saveProfile(profile(), model: makeModel(deviceAuthenticator: auth)); XCTFail("canceled review saved a provider") }
        catch is CancellationError {}
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertNil(controller.profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "lightning/profile.json").path))
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }
    func testCancelledPaymentDoesNotCreatePaymentOrPublishIntent() async throws {
        let dir = directory(), controller = try await prepared(dir), profile = try profile(), auth = Denied()
        try await controller.saveProfile(profile, model: makeModel())
        let model = makeModel(deviceAuthenticator: auth)
        let before = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { try await controller.pay(review(profile), model: model); XCTFail("canceled authentication created payment") }
        catch is CancellationError {}
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertTrue(controller.payments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), before)
    }
    func testDuplicatePaymentTapSharesWalletSpendingExclusion() async throws {
        let controller = try await prepared(directory()), profile = try profile()
        try await controller.saveProfile(profile, model: makeModel())
        let auth = Pending(), model = makeModel(deviceAuthenticator: auth), request = try review(profile)
        let entered = expectation(description: "authentication pending")
        auth.entered = { entered.fulfill() }
        let first = Task { try await controller.pay(request, model: model) }
        await fulfillment(of: [entered], timeout: 5)
        do { try await controller.pay(request, model: model); XCTFail("second tap entered authentication") }
        catch AppModel.AppError.spendAlreadyInFlight {}
        do { try await model.exclusively(.spending) {}; XCTFail("on-chain send raced Lightning authentication") }
        catch AppModel.AppError.spendAlreadyInFlight {}
        auth.continuation?.resume(throwing: CancellationError()); auth.continuation = nil
        do { try await first.value; XCTFail() } catch is CancellationError {}
        try await model.exclusively(.spending) {}
        XCTAssertTrue(controller.payments.isEmpty)
    }
    private func createIdentity(_ dir: URL, keys: InMemoryStoreKeyVault) async throws -> String {
        try await prepared(dir, keys: keys).nodeID
    }
    func testIdentityIsDurableBeforeProviderRegistrationAndStartsPaused() async throws {
        let dir = directory(), keys = InMemoryStoreKeyVault()
        let id = try await createIdentity(dir, keys: keys)
        let reopened = try await prepared(dir, keys: keys)
        XCTAssertEqual(reopened.nodeID, id)
        XCTAssertFalse(reopened.chainCurrent)
    }
    func testJournalFileProtectionWhenPlatformRecordsIt() async throws {
        // Same measured platform capability as the existing WalletCore file
        // protection suite. This is a required physical-device release check.
        try XCTSkipUnless(fileProtectionRecorded, "This simulator does not record file protection classes; verify on a physical device")
        let dir = directory()
        _ = try await prepared(dir)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "lightning/journal.v1").path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
    func testMissingJournalOrKeyNeverCreatesReplacementIdentity() async throws {
        let dir = directory(), keys = InMemoryStoreKeyVault()
        _ = try await createIdentity(dir, keys: keys)
        let bytes = try Data(contentsOf: dir.appending(path: "lightning/journal.v1"))
        do { _ = try await prepared(dir); XCTFail("missing key was replaced") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "lightning/journal.v1")), bytes)
        try FileManager.default.removeItem(at: dir.appending(path: "lightning/journal.v1"))
        do { _ = try await prepared(dir, keys: keys); XCTFail("missing journal was replaced") }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "lightning/journal.v1").path))
    }
    func testInvalidOffersAndReviewBoundsFailBeforePayment() throws {
        for text in ["", "lnbc123", "lno1notanoffer", String(repeating: "x", count: 70_000)] {
            XCTAssertThrowsError(try LightningAppController.validateOffer(text, amountSat: 5000, maximumFeeSat: 50, now: 1))
        }
        XCTAssertThrowsError(try LightningAppController.validateOffer("", amountSat: .max, maximumFeeSat: 0, now: 1))
        var value = try JSONEncoder().encode(profile())
        let string = String(decoding: value, as: UTF8.self).replacingOccurrences(of: "regtest", with: "mainnet")
        value = Data(string.utf8)
        XCTAssertThrowsError(try LightningProfile.parse(String(decoding: value, as: UTF8.self)))
    }
    func testJournalKeyRequestsDeviceOnlyWhenUnlockedProtection() throws {
        let service = "winnow-lightning-key-test-\(UUID().uuidString)", account = "journal"
        let vault = KeychainStoreKeyVault(service: service, protection: .whenUnlocked)
        defer { try? vault.discardKey(for: account) }
        _ = try vault.establishKey(for: account)
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: KeychainStoreKeyVault.accountPrefix + account, kSecReturnAttributes: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [CFString: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable] as? Bool, false)
    }
}
