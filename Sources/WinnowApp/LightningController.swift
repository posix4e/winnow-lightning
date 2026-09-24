#if WINNOW_LIGHTNING_RESEARCH
import CryptoKit
import Foundation
import LightningCore
import SwiftUI
import WalletCore

@MainActor @Observable
final class LightningController {
    var snapshot: LightningSnapshot?
    var notice: String?
    private(set) var starting = false
    @ObservationIgnored private(set) var engine: LightningEngine?
    @ObservationIgnored private(set) var driver: LightningChainDriver?
    @ObservationIgnored private(set) var transport: LightningTCP?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var relaying = false
    private(set) var feeRate: Double = 2

    enum Failure: LocalizedError {
        case unavailable, sessionChanged, packageUnsupported, channelStatePresent
        var errorDescription: String? {
            switch self {
            case .unavailable: "Open a regtest wallet and connect its Bitcoin peer first."
            case .sessionChanged: "The Lightning session changed. Reopen it before continuing."
            case .packageUnsupported: "This channel requested a transaction package this research relay does not support. Its request remains saved."
            case .channelStatePresent: "This wallet has Lightning state. Seed-only export, wallet replacement and deletion are disabled because they cannot preserve its channels."
            }
        }
    }

    func hasStoredState(_ model: AppModel) -> Bool {
        guard let root = model.storageDirectory() else { return true }
        return FileManager.default.fileExists(atPath: root.appending(path: "lightning-v1").path)
    }
    func requireNoChannelState(_ model: AppModel) throws {
        guard !hasStoredState(model) else { throw Failure.channelStatePresent }
    }

    func start(_ model: AppModel) async throws {
        guard engine == nil, !starting else { return }
        guard model.network == .regtest, let wallet = model.wallet, let walletID = model.walletID,
              let stack = model.stack, let root = model.storageDirectory() else { throw Failure.unavailable }
        starting = true
        defer { starting = false; model.keychainAuthentication.revoke() }
        let ticket = epoch
        try await model.authenticateSensitiveAction(reason: "Unlock this regtest Lightning session")
        guard ticket == epoch, model.walletID == walletID else { throw Failure.sessionChanged }
        feeRate = await model.resolvedFeeRate(priority: .medium, override: nil)
        guard ticket == epoch, model.walletID == walletID else { throw Failure.sessionChanged }
        var seed = try LightningSeed.deriveV1(secret: model.keyStore.load(walletID: walletID), network: .regtest)
        defer { seed.resetBytes(in: seed.startIndex..<seed.endIndex) }
        let directory = root.appending(path: "lightning-v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        let created = try LightningEngine(seed: seed, storageURL: directory, network: .regtest, feeRateSatPerVByte: feeRate)
        let tcp = LightningTCP(engine: created, onUpdate: { [weak self] snapshot in
            guard let self else { return }
            try await self.update(snapshot, ticket: ticket, wallet: wallet, broadcaster: stack.broadcaster)
        }, onError: { [weak self] message in
            await self?.report(message, ticket: ticket)
        })
        engine = created; transport = tcp
        driver = LightningChainDriver(engines: [created], headers: stack.chain)
        snapshot = try await created.status()
        notice = nil
        await tcp.start()
    }

    private func report(_ message: String, ticket: UUID) { if epoch == ticket { notice = message } }

    private func update(_ state: LightningSnapshot, ticket: UUID, wallet: Wallet,
                        broadcaster: TxBroadcaster) async throws {
        guard ticket == epoch, let engine, let transport else { return }
        snapshot = state
        guard state.chain_ready, !relaying else { return }
        relaying = true
        defer { relaying = false }
        for (id, event) in state.events where event.kind == "broadcast" {
            guard let package = event.transactions, package.count == 1,
                  let raw = package.first.flatMap({ Data(hex: $0) }) else { throw Failure.packageUnsupported }
            guard ticket == epoch else { throw Failure.sessionChanged }
            let reservation = await wallet.fundingReservations.first { $0.rawTransaction == raw }
            _ = try await broadcaster.broadcast(raw, feeRateSatPerVByte: reservation?.feeRateSatPerVByte)
            if let reservation {
                try await wallet.commitFundingBroadcast(requestID: reservation.requestID, rawTransaction: raw)
            }
            try await transport.consume(engine.acknowledge(eventID: id))
        }
    }

    func fundingFee(request: LightningEvent, model: AppModel) async throws -> Int64 {
        guard let wallet = model.wallet, let id = request.fundingRequestID, let amount = request.amount_sat,
              let script = request.script.flatMap({ Data(hex: $0) }),
              let address = AddressDecoder.address(for: script, network: .regtest) else { throw Failure.unavailable }
        if let saved = await wallet.fundingReservations.first(where: { $0.requestID == id }) { return saved.fee }
        return try await model.previewSend(destination: address, amount: amount, priority: .medium, override: feeRate).fee
    }

    func fund(eventID: String, request: LightningEvent, reviewedFee: Int64, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            guard let engine, let transport, let wallet = model.wallet, let requestID = request.fundingRequestID,
                  let amount = request.amount_sat, let script = request.script.flatMap({ Data(hex: $0) }) else { throw Failure.unavailable }
            let ticket = epoch
            try await model.authenticateSensitiveAction(reason: "Fund \(amount) regtest sats plus \(reviewedFee) sats fee")
            defer { model.keychainAuthentication.revoke() }
            guard ticket == epoch else { throw Failure.sessionChanged }
            let current = try await engine.status()
            guard current.chain_ready, let confirmed = current.events[eventID], confirmed.script == request.script,
                  confirmed.node_id == request.node_id, confirmed.amount_sat == amount else { throw Failure.sessionChanged }
            let existing = await wallet.fundingReservations.first { $0.requestID == requestID }
            let reserved = try await wallet.reserveChannelFunding(requestID: requestID, amount: amount, scriptPubKey: script,
                feeRateSatPerVByte: existing?.feeRateSatPerVByte ?? feeRate, chainTip: model.chainTipHeight)
            guard reserved.fee == reviewedFee else {
                if reserved.phase == .reserved { try await wallet.cancelUnsubmittedFunding(requestID: requestID) }
                throw AppModel.AppError.sendReviewChanged
            }
            let submitted = try await wallet.markFundingSubmitted(requestID: requestID)
            if submitted.phase == .submitted { try await transport.consume(engine.submitFunding(request: request, reservation: submitted)) }
            try await transport.consume(engine.acknowledge(eventID: eventID))
            await model.refresh()
        }
    }

    func connect(card: String, host: String, port: UInt16) async throws {
        struct PeerCard: Decodable { let node_id: String; let kem_key: String; let signature_key: String }
        guard let transport else { throw Failure.unavailable }
        let peer = try JSONDecoder().decode(PeerCard.self, from: Data(card.utf8))
        try await transport.connect(host: host, port: port, nodeID: peer.node_id, kemKey: peer.kem_key, signatureKey: peer.signature_key)
    }
    var identityCard: String {
        guard let snapshot, let data = try? JSONSerialization.data(withJSONObject: ["node_id": snapshot.node_id,
            "kem_key": snapshot.kem_key, "signature_key": snapshot.signature_key], options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    func openChannel(nodeID: String, amount: UInt64) async throws {
        guard let engine, let transport else { throw Failure.unavailable }
        try await transport.consume(engine.openChannel(nodeID: nodeID, amountSat: amount, userChannelID: UInt64.random(in: 1...UInt64.max)))
    }
    func receive(amountMsat: UInt64) async throws -> String {
        guard let engine, let transport else { throw Failure.unavailable }
        let id = UUID().uuidString
        let result = try await engine.createInvoice(requestID: id, amountMsat: amountMsat)
        try await transport.consume(result)
        guard let invoice = result.invoices[id] else { throw LightningError.invalidResponse }
        return invoice.invoice
    }
    func pay(invoice: String, amountMsat: UInt64, maxFeeMsat: UInt64, model: AppModel) async throws {
        guard let engine, let transport else { throw Failure.unavailable }
        let ticket = epoch
        try await model.authenticateSensitiveAction(reason: "Pay \(amountMsat) millisats over Lightning")
        defer { model.keychainAuthentication.revoke() }
        guard ticket == epoch else { throw Failure.sessionChanged }
        try await transport.consume(engine.payInvoice(invoice, amountMsat: amountMsat, maxFeeMsat: maxFeeMsat))
    }
    func close(_ channel: LightningChannel, force: Bool, model: AppModel) async throws {
        guard let engine, let transport, let wallet = model.wallet else { throw Failure.unavailable }
        let ticket = epoch
        try await model.authenticateSensitiveAction(reason: force ? "Force close this regtest channel" : "Close this regtest channel")
        defer { model.keychainAuthentication.revoke() }
        guard ticket == epoch else { throw Failure.sessionChanged }
        if force { try await transport.consume(engine.forceClose(channel)) }
        else {
            let state = try await engine.status()
            let script: Data
            if let saved = state.close_destinations[channel.channel_id], let bytes = Data(hex: saved) { script = bytes }
            else { script = try await AddressDecoder.scriptPubKey(for: wallet.freshReceiveAddress(), network: .regtest) }
            try await transport.consume(engine.closeChannel(channel, destinationScript: script))
        }
    }
    func sweep(_ event: LightningEvent, model: AppModel) async throws {
        guard let engine, let transport, let wallet = model.wallet, let id = event.output_id else { throw Failure.unavailable }
        // Save one destination per output request so retries use identical bytes.
        guard let root = model.storageDirectory() else { throw Failure.unavailable }
        let path = root.appending(path: "lightning-v1/sweep-\(id).script")
        let script: Data
        if let saved = try await engine.status().sweeps[id], let bytes = Data(hex: saved.script) { script = bytes }
        else if FileManager.default.fileExists(atPath: path.path) { script = try Data(contentsOf: path) }
        else {
            script = try await AddressDecoder.scriptPubKey(for: wallet.freshReceiveAddress(), network: .regtest)
            try script.write(to: path, options: [.atomic, .completeFileProtection])
        }
        try await transport.consume(engine.sweepOutputs(outputID: id, destinationScript: script))
    }
    func refreshFee(_ model: AppModel) async throws {
        guard let engine, let transport else { return }
        let ticket = epoch
        let updated = await model.resolvedFeeRate(priority: .medium, override: nil)
        guard ticket == epoch, updated != feeRate else { return }
        try await transport.consume(engine.setFeeRate(updated))
        feeRate = updated
    }
    func stop() async {
        epoch = UUID()
        let tcp = transport; let core = engine
        transport = nil; engine = nil; driver = nil; snapshot = nil
        await tcp?.stop()
        await core?.close()
    }
}
#endif
