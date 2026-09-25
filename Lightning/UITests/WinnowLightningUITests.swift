import Foundation
import LightningCore
import LightningLab
import Network
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

    func testSenderSharesFundedClaimAndReturns() async throws {
        try await messageJourney(sender: true)
    }

    func testRecipientClaimsWhileSenderIsStopped() async throws {
        try await messageJourney(sender: false)
    }

    private func messageJourney(sender: Bool) async throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let control = root.appending(path: "control.json")
        let portA = try await unusedPort()
        let indices = sender ? [1, 2, 3] : [0, 1, 2]
        var nodes: [Int: LightningLabNode] = [:]
        var ports: [Int: UInt16] = [:]
        for i in indices {
            let node = try LightningLabNode(directory: root.appending(path: "node-\(i)"),
                seed: Data(repeating: UInt8(91 + i), count: 32),
                bitcoinPeer: PeerEndpoint(host: BitcoinCLI.nodeHost, port: BitcoinCLI.p2pPort),
                listenPort: i == 1 ? portA : 0,
                provider: i == 1 ? LightningClaimProvider(host: "127.0.0.1", port: portA) : nil,
                forwarding: true)
            nodes[i] = node
            ports[i] = try await node.start()
        }
        let fixtures = Array(nodes.values)
        addTeardownBlock { for node in fixtures { await node.stop() }; try? FileManager.default.removeItem(at: root) }
        var cards: [Int: String] = [:]
        for i in indices { cards[i] = try await nodes[i]!.peerCard() }
        for node in fixtures {
            for card in cards.values { try await node.pin(card: card) }
            let address = try await node.wallet.freshReceiveAddress()
            _ = try BitcoinCLI.sendToAddress(wallet: "lightning-bank", address: address, sats: 600_000, feeRate: 2)
        }
        try await LightningPeerFixture.mine(1)
        for node in fixtures { try await waitFor("fixture funded through Winnow") { await node.wallet.balance == 600_000 } }
        for source in (sender ? [1, 2] : [0, 1]) {
            let from = nodes[source]!, to = nodes[source + 1]!
            try await from.connect(card: cards[source + 1]!, port: ports[source + 1]!)
            let destination = try await to.status().node_id
            try await waitFor("fixture peer connected") { try await from.status().peers.contains(destination) }
            try await from.openChannel(to: destination)
            _ = try await mempoolTransaction()
            try await LightningPeerFixture.mine(6)
            try await waitFor("fixture channel ready") {
                try await from.status().channels.contains { $0.node_id == destination && $0.usable }
            }
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": sender ? "claim-sender" : "claim-recipient", "WINNOW_E2E_RESET": "1",
            "WINNOW_E2E_ENTROPY": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_CONTROL_FILE": control.path,
            "WINNOW_E2E_PEER": "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)",
            "WINNOW_E2E_PEER_COUNT": "1", "WINNOW_E2E_SYNC_INTERVAL": "3",
        ]
        app.launch()
        defer { app.terminate() }
        tap(app, "createWalletButton")
        XCTAssertTrue(app.buttons["receiveButton"].appears(within: 60))
        if sender {
            // Receive belongs to the wallet toolbar, outside the scrollable form.
            app.buttons["receiveButton"].tap()
            tap(app, "skipReceiveAddressLabelButton")
            let address = app.staticTexts["receiveAddress"]
            XCTAssertTrue(address.appears(within: 30))
            _ = try BitcoinCLI.sendToAddress(wallet: "lightning-bank",
                address: XCTUnwrap(address.value as? String), sats: 500_000, feeRate: 2)
            app.buttons["Done"].tap()
            try await LightningPeerFixture.mine(1)
            XCTAssertTrue(poll(timeout: 90, interval: 1) { self.balance(app) == 500_000 })
        }
        try openLightning(app)
        let publicCard = try String(contentsOf: control.appendingPathExtension("peer-card"), encoding: .utf8)
        for node in fixtures { try await node.pin(card: publicCard) }
        let appID = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(publicCard.utf8)) as? [String: String])["node_id"]!
        if sender {
            try connect(app, card: cards[1]!, port: portA, control: control)
            tap(app, "openLightningChannelButton")
            tap(app, "fundLightningChannelButton")
            XCTAssertTrue(app.buttons["Sign and reserve funding"].appears(within: 30))
            app.buttons["Sign and reserve funding"].tap()
        } else {
            try connect(app, card: cards[2]!, port: ports[2]!, control: control)
            print("CLAIM_JOURNEY_PHASE recipient-channel-request")
            try await waitFor("B sees the recipient peer") { try await nodes[2]!.status().peers.contains(appID) }
            try await nodes[2]!.openChannel(to: appID)
            print("CLAIM_JOURNEY_PHASE recipient-channel-requested")
        }
        _ = try await mempoolTransaction(health: {
            if !sender { _ = try await nodes[2]!.status() }
        })
        print("CLAIM_JOURNEY_PHASE app-channel-in-mempool")
        try await LightningPeerFixture.mine(6)
        print("CLAIM_JOURNEY_PHASE app-channel-confirmed")
        let channel = app.staticTexts["lightningChannelStatus"]
        XCTAssertTrue(show(app, channel))
        XCTAssertTrue(poll(timeout: 90, interval: 1) { channel.label.contains("Ready") })
        if !sender { try connect(app, card: cards[1]!, port: portA, control: control) }
        tap(app, "messagePaymentsButton", up: true)
        let provider = nodes[1]!
        let providerID = try await provider.status().node_id
        var token: String
        var claimID: String
        if sender {
            tap(app, "prepareClaimButton")
            XCTAssertTrue(show(app, app.staticTexts["Review before committing"]))
            Screenshots.capture(app, "01-claim-quote-review", testCase: self)
            tap(app, "commitClaimButton")
            XCTAssertTrue(show(app, app.staticTexts["Funded · awaiting claim"]))
            Screenshots.capture(app, "02-claim-funded", testCase: self)
            tap(app, "shareClaimButton")
            let handoff = control.appendingPathExtension("claim")
            XCTAssertTrue(poll(timeout: 30, interval: 0.2) { FileManager.default.fileExists(atPath: handoff.path) })
            token = try String(contentsOf: handoff, encoding: .utf8)
            Screenshots.capture(app, "03-claim-share-sheet", testCase: self)
            let closeShare = app.buttons.matching(NSPredicate(format:
                "identifier == %@ OR label == %@", "header.closeButton", "Close")).firstMatch
            XCTAssertTrue(closeShare.appears(within: 15))
            closeShare.tap()
            tap(app, "copyClaimButton")
            XCTAssertEqual(try String(contentsOf: handoff, encoding: .utf8), token)
            let recipient = nodes[3]!
            let inspection = try await recipient.engine.inspectClaim(token)
            claimID = inspection.claim_id
            app.terminate()
            try await recipient.connect(card: cards[1]!, port: portA)
            try await recipient.consume(recipient.engine.importClaim(token))
            try await recipient.consume(recipient.engine.redeemClaim(id: claimID))
            try await waitFor("recipient paid while sender app is terminated") {
                try await recipient.status().claims[claimID]?.state == "received"
            }
            app.launchEnvironment["WINNOW_E2E_RESET"] = "0"
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Settings"].appears(within: 60))
            try openLightning(app)
            try connect(app, card: cards[1]!, port: portA, control: control)
            tap(app, "messagePaymentsButton", up: true)
            XCTAssertTrue(show(app, app.staticTexts["Payment settled"]))
            Screenshots.capture(app, "04-claim-sender-returned-paid", testCase: self)
            let recipientState = try await recipient.status()
            let intermediateID = try await nodes[2]!.status().node_id
            XCTAssertEqual(recipientState.channels.count, 1)
            XCTAssertEqual(recipientState.channels.first?.node_id, intermediateID)
        } else {
            let source = nodes[0]!
            try await source.consume(source.engine.prepareClaim(requestID: "recipient-ui", provider: providerID,
                host: "127.0.0.1", port: portA, amountMsat: 5_000_000))
            try await waitFor("sender quote") { try await source.status().claims.values.contains { $0.state == "quoted" } }
            let sourceState = try await source.status()
            let quoted = try XCTUnwrap(sourceState.claims.values.first { $0.state == "quoted" })
            claimID = quoted.claim_id
            try await source.consume(source.engine.commitClaim(quoted))
            try await waitFor("sender claim funded") { try await source.status().claims[claimID]?.state == "awaiting_claim" }
            token = try await source.engine.exportClaim(id: claimID)
            await source.stop()
            try paste(token, control: control)
            tap(app, "pasteClaimButton")
            tap(app, "importClaimButton")
            XCTAssertTrue(show(app, app.staticTexts["Verified · ready to claim"]))
            Screenshots.capture(app, "01-recipient-verifies-claim", testCase: self)
            tap(app, "redeemClaimButton")
            XCTAssertTrue(show(app, app.staticTexts["Payment received"]))
            Screenshots.capture(app, "02-recipient-payment-received", testCase: self)
        }
        XCTAssertEqual(try BitcoinCLI.mempoolTxids(), [])
        print("CLAIM_JOURNEY role=\(sender ? "sender" : "recipient") claim=\(claimID) amount_msat=5000000 fee_msat=100000 sender_stopped=true route=S-A-B-R token_bytes=\(token.utf8.count)")
    }

    private func unusedPort() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "fixture.port"))
        }
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
            let exists = element.appears(within: 0.5)
            let frame = exists ? element.frame : .zero
            let safeTop = max(120, app.navigationBars.firstMatch.frame.maxY + 12)
            let safeBottom = app.frame.maxY - 100
            if exists, element.isHittable, frame.midY > safeTop, frame.midY < safeBottom { return true }
            // SwiftUI may report a clipped control under the navigation bar as
            // hittable. Bring its center into the form before synthesizing a tap.
            let moveUp = exists && frame.height > 0 ? frame.midY <= safeTop : up
            // Use the form's margin, outside editors that scroll their own text.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: moveUp ? 0.3 : 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: moveUp ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
        }
        print(app.debugDescription)
        return false
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
        let field = app.textFields["lightningPort"]
        XCTAssertTrue(show(app, field, up: true))
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + String(port))
        app.dismissKeyboard()
        try paste(card, control: control)
        tap(app, "pasteLightningPeerButton")
        tap(app, "connectLightningButton")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: String])
        let nodeID = try XCTUnwrap(fields["node_id"])
        XCTAssertTrue(app.buttons["Open channel to \(nodeID.prefix(12))…"].appears(within: 30))
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
    private func mempoolTransaction(health: () async throws -> Void = {}) async throws -> String {
        for _ in 0..<300 {
            try await health()
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
