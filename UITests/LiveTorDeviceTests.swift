import XCTest

/// Selected explicitly by scripts/check-live-tor-ui on device or simulator.
/// Public-network availability is excluded from ordinary simulator CI.
@MainActor
final class LiveTorDeviceTests: XCTestCase {
    func testRealTorForegroundRecovery() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["WINNOW_LIVE_TOR_UI"] == "1" else {
            throw XCTSkip("Run scripts/check-live-tor-ui for the live Tor simulator journey")
        }
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "live-tor-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_RESET": "1", "WINNOW_E2E_ADVANCED": "1",
            "WINNOW_E2E_NETWORK": "mainnet", "WINNOW_E2E_TAB": "settings",
            "WINNOW_E2E_PEER": "uvqowejn43rwe2gryjqy7p6izluyzs777sowpkwcbduo2v4zdybesqad.onion:8333"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["createWalletButton"].waitForExistence(timeout: 120))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        app.buttons["createWalletButton"].tap()
        let written = app.switches["writtenDownToggle"]
        XCTAssertTrue(written.waitForExistence(timeout: 30))
        app.flipSwitch(written)
        let done = app.buttons["backupDoneButton"]
        XCTAssertTrue(scrollUntilExists(app, done, maxSwipes: 5))
        done.tap()
        let toggle = app.switches["torEnabledToggle"]
        XCTAssertTrue(scrollUntilExists(app, toggle, maxSwipes: 6))
        capture(app, "device-tor-default-off")
        app.flipSwitch(toggle)
        waitForReady(app)
        capture(app, "device-tor-ready")
        backgroundAndReturn(app)
        waitForReady(app)
        capture(app, "device-tor-foreground-recovered")
        let peers = app.buttons["refreshPeersButton"]
        XCTAssertTrue(scrollUntilExists(app, peers, maxSwipes: 14))
        let onion = app.staticTexts.matching(identifier: "peerEndpoint")
            .matching(NSPredicate(format: "label CONTAINS %@", ".onion:")).firstMatch
        XCTAssertTrue(poll(timeout: 180, interval: 3, "a real onion Bitcoin handshake after foreground recovery") {
            peers.tap()
            return onion.waitForExistence(timeout: 2)
        })
        capture(app, "device-tor-onion-bitcoin")
        let refresh = app.buttons["refreshPeerCatalogButton"]
        XCTAssertTrue(scrollUntilExists(app, refresh, maxSwipes: 14, up: true))
        refresh.tap()
        let notice = app.staticTexts["peerCatalogNotice"]
        let error = app.staticTexts["peerCatalogError"]
        XCTAssertTrue(poll(timeout: 150, interval: 2, "the proxied census response") { notice.exists || error.exists })
        capture(app, "device-tor-census-response")
        XCTAssertFalse(error.exists, error.exists ? error.label : "")
        XCTAssertTrue(notice.exists)
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForReady(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "State, Ready"),
                                               object: app.staticTexts["torState"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 330), .completed,
                       "Real Arti bootstrap or foreground recovery failed")
    }
}
