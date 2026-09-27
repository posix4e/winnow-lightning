import LightningCore
import SwiftUI

struct LightningLiquidityView: View {
    @Environment(AppModel.self) private var model
    let controller: LightningAppController
    @State private var capacity = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text(controller.profile?.name ?? "Choose a provider").font(.headline)
                Text("The provider supplies receiving capacity. Your keys stay on this device. Its setup invoice pays for a channel; that payment is a fee, not a deposit into your wallet.")
                    .font(.footnote)
            }
            if let quote = controller.liquidityQuote {
                quoteSection(quote)
            }
            if let provider = LightningProviders.provider(controller.profile), provider.manualSetup {
                Section("Set up on the provider's website") {
                    Text("LNServer uses website setup. Copy this wallet's node ID, choose a private channel, and review the fee on LNServer before paying. Winnow does not pay the fee for you.")
                    Text(controller.nodeID).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("lightningSetupNodeID").accessibilityValue(controller.nodeID)
                    Button("Copy wallet node ID") { ClipboardPolicy.interchange.apply(controller.nodeID) }
                    Link("Open LNServer setup", destination: provider.website)
                    Button("Sync and check receiving capacity") { run { await model.syncNow(); await controller.resume(model: model) } }
                }
            } else if controller.liquidityQuote?.accepted != true {
                Section("Receiving capacity") {
                    if let info = controller.liquidityInfo {
                        LabeledContent("Provider minimum", value: "\(info.minimumCapacitySat) sats")
                        TextField("Capacity in sats", text: $capacity).keyboardType(.numberPad)
                            .accessibilityIdentifier("lightningInboundCapacity")
                        Button("Get setup fee quote") { run {
                            guard let sats = UInt64(capacity) else { throw LightningError.invalidAmount }
                            try await controller.quoteLiquidity(capacitySat: sats, model: model)
                        } }.accessibilityIdentifier("lightningQuoteCapacity")
                    } else {
                        Button("Check provider options") { run {
                            try await controller.prepareLiquidity(model: model)
                            capacity = String(controller.liquidityInfo?.minimumCapacitySat ?? 0)
                        } }.disabled(!controller.chainCurrent).accessibilityIdentifier("lightningProviderOptions")
                        if !controller.chainCurrent {
                            Text("Bitcoin is still syncing. Provider setup becomes available after Winnow verifies the chain.")
                                .accessibilityIdentifier("lightningSetupWaitingForChain")
                        }
                    }
                }
            }
            Section {
                if busy { ProgressView("Checking provider…") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningLiquidityError") }
                Text("Channels require at least three block confirmations. Keep Winnow open while setup completes. This beta has no external watchtower; background checks run when iOS allows them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up receiving")
        .disabled(busy)
    }
    @ViewBuilder private func quoteSection(_ quote: LightningAppController.LiquidityQuote) -> some View {
        Section("Review setup fee") {
            LabeledContent("Setup fee", value: "\(quote.feeSat) sats").accessibilityIdentifier("lightningSetupFee")
            LabeledContent("Channel capacity", value: "\(quote.request.lspBalanceSat) sats")
            LabeledContent("Minimum lease", value: "\(quote.request.channelExpiryBlocks) blocks")
            LabeledContent("Confirmations", value: "\(quote.request.requiredChannelConfirmations)")
            Text("This purchases capacity to receive payments. The capacity is not your wallet balance.").font(.footnote)
            if quote.accepted {
                LabeledContent("Setup status", value: quote.order.orderState).accessibilityIdentifier("lightningSetupStatus")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                if quote.isPayable(network: controller.network, now: UInt64(context.date.timeIntervalSince1970)) {
                    Text("Pay this setup invoice from another Lightning wallet or Kraken. You will create a separate receive invoice after the channel is confirmed.")
                    QRCodeView(content: quote.invoice.uppercased()).frame(width: 240, height: 240).frame(maxWidth: .infinity)
                    Text(quote.invoice).font(.caption.monospaced()).lineLimit(3)
                        .accessibilityIdentifier("lightningSetupInvoice").accessibilityValue(quote.invoice)
                    Button("Copy setup fee invoice") { ClipboardPolicy.interchange.apply(quote.invoice) }
                        .accessibilityIdentifier("lightningCopySetupInvoice")
                    ShareLink("Share setup fee invoice", item: quote.invoice)
                } else { Text("This invoice is paid, expired, or unavailable. Check the order status and sync before creating another setup order.") }
                }
                Button("Check setup payment and sync") { run { try await controller.refreshLiquidityOrder(model: model) } }
                    .accessibilityIdentifier("lightningCheckSetup")
            } else {
                Text("Winnow will show the payment invoice after you approve this fee. Approval does not send funds.").font(.footnote)
                Button("Approve \(quote.feeSat)-sat setup fee") { run { try await controller.acceptLiquidityQuote(model: model) } }
                    .accessibilityIdentifier("lightningApproveSetupFee")
            }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
