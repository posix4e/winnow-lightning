import Foundation
import LightningCore
import TestSupport
import WalletCore
import XCTest

@MainActor
final class WinnowLightningUITests: XCTestCase {
    func testFundingPaymentRestartAndClose() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        let chain = try BitcoinCLI.runObject(["getblockchaininfo"])
        XCTAssertEqual(chain["chain"] as? String, "regtest")
        XCTAssertGreaterThanOrEqual(try BitcoinCLI.trustedBalanceSats(wallet: "lightning-bank"), 500_000)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let control = root.appending(path: "control.json")
        let peer = try LightningPeerFixture(directory: root)
        let port = try await peer.start()
        addTeardownBlock { await peer.stop(); try? FileManager.default.removeItem(at: root) }
        let card = try await peer.peerCard()
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "lightning", "WINNOW_E2E_RESET": "1",
            "WINNOW_E2E_ENTROPY": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_CONTROL_FILE": control.path,
            "WINNOW_E2E_PEER": "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)",
            "WINNOW_E2E_PEER_COUNT": "1", "WINNOW_E2E_SYNC_INTERVAL": "3",
        ]
        app.launch()
        defer { app.terminate() }
        tap(app, "createWalletButton")
        XCTAssertTrue(app.buttons["receiveButton"].appears(within: 60))
        app.buttons["receiveButton"].tap()
        tap(app, "skipReceiveAddressLabelButton")
        let address = app.staticTexts["receiveAddress"]
        XCTAssertTrue(address.appears(within: 30))
        let receiveAddress = try XCTUnwrap(address.value as? String)
        _ = try AddressDecoder.scriptPubKey(for: receiveAddress, network: .regtest)
        Screenshots.capture(app, "01-lightning-receive", testCase: self)
        app.buttons["Done"].tap()
        let deposit = try BitcoinCLI.sendToAddress(wallet: "lightning-bank", address: receiveAddress, sats: 500_000, feeRate: 2)
        try await LightningPeerFixture.mine(1)
        XCTAssertTrue(poll(timeout: 90, interval: 1, "Winnow discovers its regtest deposit") {
            self.balance(app) == 500_000
        })
        Screenshots.capture(app, "02-lightning-wallet-funded", testCase: self)
        try openLightning(app)
        try connect(app, card: card, port: port, control: control)
        tap(app, "openLightningChannelButton")
        tap(app, "fundLightningChannelButton")
        XCTAssertTrue(app.buttons["Sign and reserve funding"].appears(within: 30))
        Screenshots.capture(app, "03-lightning-funding-review", testCase: self)
        app.buttons["Sign and reserve funding"].tap()
        let funding = try await mempoolTransaction()
        let raw = try BitcoinCLI.run(["getrawtransaction", funding])
        let transaction = try Transaction.decode(XCTUnwrap(Data(hex: raw)))
        XCTAssertTrue(transaction.inputs.contains { $0.previousOutput.txid.displayHex == deposit })
        XCTAssertTrue(transaction.outputs.contains { $0.value == 100_000 && $0.scriptPubKey.prefix(2) == Data([0, 32]) })
        try await LightningPeerFixture.mine(6)
        try await waitFor("peer sees a usable channel") { try await peer.status().channels.first?.usable == true }
        let channel = app.staticTexts["lightningChannelStatus"]
        XCTAssertTrue(show(app, channel))
        XCTAssertTrue(poll(timeout: 90, interval: 1, "app sees its channel ready") { channel.label.contains("Ready") })
        Screenshots.capture(app, "04-lightning-channel-ready", testCase: self)
        let first = try await peer.invoice("before-restart")
        try await pay(app, invoice: first, peer: peer, control: control)
        Screenshots.capture(app, "05-lightning-payment-sent", testCase: self)
        XCTAssertEqual(try BitcoinCLI.mempoolTxids(), [], "Lightning payment should not broadcast a Bitcoin transaction")

        app.terminate()
        app.launchEnvironment["WINNOW_E2E_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].appears(within: 60))
        try openLightning(app)
        try connect(app, card: card, port: port, control: control)
        let restored = app.staticTexts["lightningPayment-\(first.payment_hash)"]
        XCTAssertTrue(show(app, restored))
        XCTAssertTrue(restored.label.contains("sent"), "Payment history must survive an app restart")
        Screenshots.capture(app, "06-lightning-restarted", testCase: self)
        let second = try await peer.invoice("after-restart")
        try await pay(app, invoice: second, peer: peer, control: control)
        Screenshots.capture(app, "07-lightning-payment-after-restart", testCase: self)
        tap(app, "closeLightningChannelButton")
        let closing = try await mempoolTransaction()
        let closeRaw = try BitcoinCLI.run(["getrawtransaction", closing])
        let closeTX = try Transaction.decode(XCTUnwrap(Data(hex: closeRaw)))
        XCTAssertTrue(closeTX.inputs.contains { $0.previousOutput.txid.displayHex == funding })
        try await LightningPeerFixture.mine(6)
        try await waitFor("peer sees the channel closed") { try await peer.status().channels.isEmpty }
        let empty = app.staticTexts["lightningNoChannels"]
        XCTAssertTrue(show(app, empty))
        Screenshots.capture(app, "08-lightning-channel-closed", testCase: self)
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(poll(timeout: 90, interval: 1, "Winnow discovers the returned channel balance") {
            self.balance(app) > 490_000 && self.balance(app) < 496_000
        })
        let receipt = app.buttons["historyPayment-\(closing)"]
        XCTAssertTrue(show(app, receipt))
        Screenshots.capture(app, "09-lightning-funds-returned", testCase: self)
        print("LIGHTNING_JOURNEY funding=\(funding) payments=\(first.payment_hash),\(second.payment_hash) close=\(closing) balance=\(balance(app))")
    }

    private func balance(_ app: XCUIApplication) -> Int64 {
        Int64(balanceText(app).filter(\.isNumber)) ?? -1
    }
    private func paste(_ text: String, control: URL) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: control, options: .atomic)
    }
    private func tap(_ app: XCUIApplication, _ id: String, up: Bool = false) {
        let button = app.buttons[id]
        XCTAssertTrue(show(app, button, up: up), "Missing \(id)")
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "\(id) enabled") { button.isEnabled })
        button.tap()
    }
    private func show(_ app: XCUIApplication, _ element: XCUIElement, up: Bool = false) -> Bool {
        for _ in 0..<16 {
            if element.appears(within: 0.5), element.isHittable { return true }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
        }
        print(app.debugDescription)
        return element.exists && element.isHittable
    }
    private func openLightning(_ app: XCUIApplication) throws {
        app.tabBars.buttons["Settings"].tap()
        tap(app, "openLightningButton")
        tap(app, "unlockLightningButton")
        XCTAssertTrue(poll(timeout: 90, interval: 1, "Lightning catches up through Winnow") {
            app.staticTexts["lightningScanStatus"].label == "Channel scan caught up"
        })
    }
    private func connect(_ app: XCUIApplication, card: String, port: UInt16, control: URL) throws {
        try paste(card, control: control)
        tap(app, "pasteLightningPeerButton")
        let field = app.textFields["lightningPort"]
        XCTAssertTrue(show(app, field, up: true))
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + String(port))
        app.dismissKeyboard()
        tap(app, "connectLightningButton")
        XCTAssertTrue(app.buttons["openLightningChannelButton"].appears(within: 30))
    }
    private func pay(_ app: XCUIApplication, invoice: LightningInvoice, peer: LightningPeerFixture, control: URL) async throws {
        try paste(invoice.invoice, control: control)
        tap(app, "pasteLightningInvoiceButton", up: true)
        tap(app, "payLightningButton")
        let receipt = app.staticTexts["lightningPayment-\(invoice.payment_hash)"]
        XCTAssertTrue(show(app, receipt))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "Lightning payment sent") { receipt.label.contains("sent") })
        try await waitFor("peer claims the exact invoice") {
            try await peer.status().events.values.contains {
                $0.kind == "payment_received" && $0.payment_hash == invoice.payment_hash && $0.amount_msat == 2_000_000
            }
        }
    }
    private func mempoolTransaction() async throws -> String {
        for _ in 0..<300 {
            let txids = try BitcoinCLI.mempoolTxids()
            if txids.count == 1 { return txids[0] }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LightningError.native("No unique transaction reached the regtest mempool")
    }
    private func waitFor(_ message: String, condition: () async throws -> Bool) async throws {
        for _ in 0..<600 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Timed out: \(message)")
        throw LightningError.invalidResponse
    }
}
