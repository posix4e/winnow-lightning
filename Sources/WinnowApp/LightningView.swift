import Foundation
import LightningCore
import SwiftUI
import WalletCore

struct LightningView: View {
    @Environment(AppModel.self) private var model
    let controller: LightningAppController
    @State private var setup = false
    @State private var send = false
    @State private var capacity = "100000"
    @State private var review: LightningReview?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Regtest research beta").font(.headline)
                    Text("Test coins only. Keep the app open to verify the chain and recover funds. This beta does not protect channels while the app is stopped.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Older wallet data stays on this device. This version uses a separate Swift regtest wallet.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Connection", value: controller.connection)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Connection").accessibilityValue(controller.connection)
                        .accessibilityIdentifier("lightningConnection")
                    if let error = controller.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningError") }
                    Button("Sync and reconnect") { run { await model.syncNow() } }.accessibilityIdentifier("lightningSync")
                }
                providerSection
                channelSection
                receiveSection
                Section("Payments") {
                    Button("Pay a receive offer") { send = true }.accessibilityIdentifier("lightningSend")
                        .disabled(!controller.channels.contains(where: { $0.phase == .ready }))
                    ForEach(controller.payments.reversed(), id: \.id) { payment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(payment.incoming ? "Received" : "Sent") \(payment.amountMsat / 1000) sats")
                            Text(payment.phase.displayName).foregroundStyle(payment.phase == .settled ? .green : .secondary)
                                .accessibilityIdentifier("lightningPaymentPhase.\(payment.id.hex)")
                            if let fee = payment.feeMsat { Text("Fee: \(fee) msat").font(.caption) }
                            Text(payment.hash.hex).font(.caption.monospaced()).textSelection(.enabled)
                                .accessibilityLabel("Payment hash").accessibilityValue(payment.hash.hex)
                                .accessibilityIdentifier("lightningPaymentHash.\(payment.hash.hex)")
                        }
                    }
                }
            }
            .navigationTitle("Lightning")
            .disabled(busy)
            .sheet(isPresented: $setup) { LightningSetupView(controller: controller) }
            .sheet(isPresented: $send) { LightningSendView(controller: controller) }
            .sheet(item: $review) { LightningReviewView(controller: controller, review: $0) }
            .task {
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { controller.error = error.localizedDescription; return }
                }
            }
        }
    }
    private var providerSection: some View {
        Section("Provider") {
            Text(controller.profile?.name ?? "No provider configured")
            if let profile = controller.profile { Text(profile.endpoint).font(.caption.monospaced()) }
            Button("Configure provider") { setup = true }.accessibilityIdentifier("lightningSetup")
            LabeledContent("Your node ID") {
                Text(controller.nodeID).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityLabel("Your node ID").accessibilityValue(controller.nodeID)
                    .accessibilityIdentifier("lightningNodeID")
            }
            Button("Copy node ID") { UIPasteboard.general.string = controller.nodeID }.disabled(controller.nodeID.isEmpty)
        }
    }
    private var channelSection: some View {
        Section("Channels") {
            if controller.channels.isEmpty {
                TextField("Capacity in sats", text: $capacity).keyboardType(.numberPad).accessibilityIdentifier("lightningCapacity")
                Button("Request a channel") { run {
                    guard let amount = UInt64(capacity) else { throw LightningError.invalidAmount }
                    try await controller.openChannel(capacitySat: amount)
                } }.disabled(controller.profile == nil).accessibilityIdentifier("lightningOpen")
            }
            ForEach(controller.channels, id: \.id) { channel in
                VStack(alignment: .leading) {
                    Text("\(channel.capacitySat) sats · \(channel.phase.rawValue)").accessibilityIdentifier("lightningChannelPhase")
                    if let balance = controller.balances.first(where: { $0.id == channel.id }) {
                        Text("Local balance: \(balance.localMsat / 1000) sats").font(.caption)
                    }
                    if [.ready, .closing].contains(channel.phase) {
                        Button("Review channel close") { run {
                            review = try await .close(controller.reviewClose(channel, force: false, model: model))
                        } }
                            .buttonStyle(.borderless).accessibilityIdentifier("lightningClose")
                        Button("Review force close", role: .destructive) { run {
                            review = try await .close(controller.reviewClose(channel, force: true, model: model))
                        } }
                            .buttonStyle(.borderless).accessibilityIdentifier("lightningForceClose")
                    }
                }
            }
            ForEach(controller.funding, id: \.temporaryID) { request in
                Button("Review funding \(request.amountSat) sats") { run {
                    review = try await .funding(controller.reviewFunding(request, model: model))
                } }.accessibilityIdentifier("lightningFundingReview")
            }
        }
    }
    private var receiveSection: some View {
        Section("Receive") {
            Button("Create receive offer") { run { try await controller.registerOffer(model: model) } }
                .disabled(controller.profile?.receive == nil).accessibilityIdentifier("lightningCreateOffer")
            ForEach(controller.offers, id: \.id) { offer in
                Text("Reusable until \(Date(timeIntervalSince1970: TimeInterval(offer.expiresAt)).formatted())").font(.caption)
                Text(offer.offer.string).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                    .accessibilityLabel("Receive offer").accessibilityValue(offer.offer.string)
                    .accessibilityIdentifier("lightningReceiveOffer")
                ShareLink("Share receive offer", item: offer.offer.string).accessibilityIdentifier("lightningShareOffer")
                Button("Copy receive offer") { UIPasteboard.general.string = offer.offer.string }.accessibilityIdentifier("lightningCopyOffer")
            }
            Text("Share your reusable receive offer in your favorite messenger. The recipient must return before the payment expires.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); controller.error = nil }
            catch { controller.error = error.localizedDescription }
        }
    }
}

extension LightningEngine.PaymentPhase {
    var displayName: String {
        switch self {
        case .preparing: "Preparing"
        case .inFlight: "Committing payment"
        case .awaitingRecipient: "Awaiting recipient"
        case .recovering: "Recovering on chain"
        case .settled: "Settled"
        case .failed: "Failed"
        }
    }
}
