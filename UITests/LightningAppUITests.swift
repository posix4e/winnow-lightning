import Foundation
import TestSupport
import UIKit
import WalletCore
import XCTest

/// Runs both Swift clients in separate namespaces. The host kills each actual
/// app PID, while stock LDK providers persist and settle the held payment.
@MainActor
final class LightningAppUITests: XCTestCase {
    private var config: [String: String] = [:]
    private var control: URL!
    private var setup: [String: Any] = [:]

    func testAsyncOfferAcrossActualAppCrashes() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WINNOW_LIGHTNING_UI_FIXTURE"], "Run scripts/ci-lightning-ui with a fresh fixture")
        config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        setup = try rpc("status")
        control = FileManager.default.temporaryDirectory.appending(path: "lightning-control-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: control) }
        let app = XCUIApplication()
        defer { app.terminate() }

        try launch(app, role: "recipient", fresh: true)
        try configure(app, profile: XCTUnwrap(setup["recipient"] as? [String: Any]))
        try waitConnected(app)
        let recipientProfile = try rpc("recipient_channel")
        try configure(app, profile: recipientProfile)
        try waitConnected(app)
        tap(app, "lightningCreateOffer")
        let offerElement = app.staticTexts["lightningReceiveOffer"]
        XCTAssertTrue(scrollUntilExists(app, offerElement))
        XCTAssertTrue(offerElement.appears(within: 60))
        let offer = try XCTUnwrap(offerElement.value as? String)
        XCTAssertTrue(offer.hasPrefix("lno1"))
        tap(app, "lightningCopyOffer")
        XCTAssertEqual(try clipboard(), offer, "Copy changed the reusable offer bytes")
        Screenshots.capture(app, "lightning-01-reusable-offer", testCase: self)
        tap(app, "lightningShareOffer")
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.appears(within: 15), "Apple Share sheet did not open: \(app.debugDescription)")
        Screenshots.capture(app, "lightning-02-apple-share", testCase: self)
        copy.tap()
        XCTAssertEqual(try clipboard(), offer, "Apple Share changed the offer bytes")
        try killed(app, response: rpc("kill", values: ["role": "recipient"]))

        try launch(app, role: "sender", fresh: true)
        try fundWallet(app)
        try configure(app, profile: XCTUnwrap(setup["sender"] as? [String: Any]))
        try waitConnected(app)
        tap(app, "lightningOpen")
        let funding = app.buttons["lightningFundingReview"]
        XCTAssertTrue(scrollUntilExists(app, funding))
        XCTAssertTrue(funding.appears(within: 60))
        funding.tap()
        XCTAssertTrue(app.buttons["lightningConfirm"].appears(within: 20))
        Screenshots.capture(app, "lightning-03-funding-review", testCase: self)
        // Canceling review leaves no transaction in the independent node.
        app.buttons["lightningCancel"].tap()
        _ = try rpc("assert_no_funding")
        funding.tap()
        app.buttons["lightningConfirm"].tap()
        _ = try rpc("confirm_funding")
        XCTAssertTrue(poll(timeout: 90, interval: 1, "app verifies channel funding") {
            app.staticTexts["lightningChannelPhase"].label.contains("ready")
        })
        try paste(offer)
        tap(app, "lightningSend")
        app.buttons["lightningPasteOffer"].tap()
        app.typeInto("lightningAmount", "5000")
        app.buttons["lightningReviewPayment"].tap()
        XCTAssertTrue(app.buttons["lightningConfirm"].appears(within: 15))
        XCTAssertTrue(app.staticTexts["Amount, 5000 sats"].exists)
        XCTAssertTrue(app.staticTexts["Maximum fee, 50 sats"].exists)
        XCTAssertTrue(app.staticTexts["Maximum expiry, 2016 blocks"].exists)
        Screenshots.capture(app, "lightning-04-payment-review", testCase: self)
        tap(app, "lightningConfirm")
        XCTAssertTrue(app.navigationBars["Review Lightning"].disappears(within: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["lightningSendDone"].disappears(within: 15), app.debugDescription)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Awaiting recipient"]))
        XCTAssertTrue(app.staticTexts["Awaiting recipient"].appears(within: 60))
        XCTAssertFalse(app.staticTexts["Settled"].exists)
        Screenshots.capture(app, "lightning-05-awaiting-offline-recipient", testCase: self)
        try killed(app, response: rpc("hold_and_kill"))

        try launch(app, role: "recipient", fresh: false)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Settled"]))
        XCTAssertTrue(app.staticTexts["Settled"].appears(within: 90))
        let settled = try rpc("recipient_settled")
        let hash = try XCTUnwrap(settled["hash"] as? String)
        try verifyHash(app, hash: hash)
        Screenshots.capture(app, "lightning-06-recipient-settled-sender-stopped", testCase: self)
        try killed(app, response: rpc("kill", values: ["role": "recipient"]))

        try launch(app, role: "sender", fresh: false)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Settled"]))
        XCTAssertTrue(app.staticTexts["Settled"].appears(within: 90))
        try verifyHash(app, hash: hash)
        XCTAssertEqual(app.staticTexts.matching(identifier: "lightningPaymentHash." + hash).count, 1, "settlement duplicated on sender restart")
        Screenshots.capture(app, "lightning-07-sender-reconciled-once", testCase: self)
        _ = try rpc("finish")
        tap(app, "lightningClose", up: true)
        XCTAssertTrue(app.staticTexts["Maximum negotiated fee, 905 sats"].appears(within: 15))
        Screenshots.capture(app, "lightning-08-close-review", testCase: self)
        tap(app, "lightningConfirm")
        XCTAssertTrue(app.navigationBars["Review Lightning"].disappears(within: 30), app.debugDescription)
        let closed = try rpc("mine_close")
        let expectedBalance = try XCTUnwrap(closed["expected_balance"] as? Int64)
        selectTab(app, "Wallet")
        XCTAssertTrue(poll(timeout: 90, interval: 1, "wallet discovers returned channel funds") {
            Int64(self.balanceText(app).filter(\.isNumber)) == expectedBalance
        })
        Screenshots.capture(app, "lightning-09-returned-wallet-funds", testCase: self)
    }

    private func selectTab(_ app: XCUIApplication, _ name: String) {
        // iPadOS 18 exposes the top tab strip outside the TabBar hierarchy.
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.appears(within: 60), app.debugDescription)
        button.tap()
    }
    private func launch(_ app: XCUIApplication, role: String, fresh: Bool) throws {
        let run = try XCTUnwrap(setup["run"] as? String)
        app.launchEnvironment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": run + "-" + role,
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": String(repeating: role == "recipient" ? "02" : "01", count: 16),
            "WINNOW_E2E_PEER": try XCTUnwrap(setup["bitcoin_peer"] as? String), "WINNOW_E2E_PEER_COUNT": "1",
            "WINNOW_E2E_SYNC_INTERVAL": "3", "WINNOW_E2E_TAB": "lightning", "WINNOW_E2E_CONTROL_FILE": control.path]
        if fresh { app.launchEnvironment["WINNOW_E2E_RESET"] = "1" }
        app.launch()
        if fresh {
            XCTAssertTrue(app.buttons["createWalletButton"].appears(within: 60))
            app.buttons["createWalletButton"].tap()
        }
        selectTab(app, "Lightning")
        let node = app.staticTexts["lightningNodeID"]
        XCTAssertTrue(scrollUntilExists(app, node))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "durable node identity") { (node.value as? String)?.count == 66 })
        _ = try rpc("register", values: ["role": role, "node": XCTUnwrap(node.value as? String)])
    }
    private func configure(_ app: XCUIApplication, profile: [String: Any]) throws {
        try paste(String(decoding: JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]), as: UTF8.self))
        tap(app, "lightningSetup", up: true)
        XCTAssertTrue(app.buttons["lightningPasteProfile"].appears(within: 15))
        app.buttons["lightningPasteProfile"].tap()
        tap(app, "lightningReviewProfile")
        XCTAssertTrue(app.buttons["lightningConfirm"].appears(within: 15))
        tap(app, "lightningConfirm")
        try dismissInput(app, done: "lightningSetupDone")
    }
    private func dismissInput(_ app: XCUIApplication, done: String) throws {
        XCTAssertTrue(app.buttons["lightningConfirm"].disappears(within: 30), app.debugDescription)
        let button = app.buttons[done]
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "input sheet is visible after approval") { button.isHittable })
        XCTAssertTrue(tapVisibleCenter(app, button))
        XCTAssertTrue(button.disappears(within: 15))
    }
    private func waitConnected(_ app: XCUIApplication) throws {
        let connection = app.descendants(matching: .any)["lightningConnection"].firstMatch
        XCTAssertTrue(scrollUntilExists(app, connection, up: true))
        XCTAssertTrue(poll(timeout: 90, interval: 0.5, "authenticated provider connection") {
            connection.value as? String == "Connected"
        }, connection.debugDescription)
    }
    private func fundWallet(_ app: XCUIApplication) throws {
        selectTab(app, "Wallet")
        app.buttons["receiveButton"].tap()
        XCTAssertTrue(app.buttons["skipReceiveAddressLabelButton"].appears(within: 20))
        app.buttons["skipReceiveAddressLabelButton"].tap()
        let address = try XCTUnwrap(app.staticTexts["receiveAddress"].value as? String)
        _ = try AddressDecoder.scriptPubKey(for: address, network: .regtest)
        app.buttons["Done"].tap()
        _ = try rpc("fund_wallet", values: ["address": address])
        XCTAssertTrue(poll(timeout: 90, interval: 1, "Winnow discovers regtest funding") {
            Int64(self.balanceText(app).filter(\.isNumber)) == 2_000_000
        })
        selectTab(app, "Lightning")
    }
    private func tap(_ app: XCUIApplication, _ identifier: String, up: Bool = false) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scrollUntilExists(app, button, up: up, fullyVisible: true))
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(tapVisibleCenter(app, button))
    }
    private func verifyHash(_ app: XCUIApplication, hash: String) throws {
        let value = app.staticTexts["lightningPaymentHash." + hash]
        XCTAssertTrue(scrollUntilExists(app, value, fullyVisible: true), app.debugDescription)
        XCTAssertEqual(value.value as? String, hash)
    }
    private func paste(_ text: String) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: control, options: .atomic)
    }
    private func killed(_ app: XCUIApplication, response: [String: Any]) throws {
        XCTAssertEqual(response["signal"] as? String, "SIGKILL")
        XCTAssertEqual(response["running"] as? Bool, false, "host must verify the real PID has exited")
        // Discard XCTest's cached running state only after the host has killed
        // and reaped the process. This is not the crash mechanism.
        app.terminate()
    }
    private func clipboard() throws -> String {
        // The test runner is a background app and cannot read another app's
        // pasteboard on current iOS. Inspect the actual simulator pasteboard.
        try XCTUnwrap(rpc("clipboard")["text"] as? String)
    }
    private func rpc(_ command: String, values: [String: String] = [:]) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: values.merging(["command": command]) { _, new in new })
        let response = try HostProcess.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--max-time", "120", "-X", "POST",
            "-H", "Authorization: Bearer " + XCTUnwrap(config["token"]), "-H", "Content-Type: application/json",
            "--data-binary", "@-", XCTUnwrap(config["url"])], input: input)
        XCTAssertEqual(response.status, 0, response.stderr)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(value["ok"] as? Bool, true, String(describing: value["error"]))
        return try XCTUnwrap(value["result"] as? [String: Any])
    }
}
