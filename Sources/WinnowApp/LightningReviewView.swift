import LightningCore
import SwiftUI
import WalletCore

enum LightningReview: Identifiable {
    case profile(LightningProfile)
    case funding(LightningAppController.FundingReview)
    case payment(LightningAppController.PaymentReview)
    case close(LightningAppController.CloseReview)
    var id: String {
        switch self {
        case .profile(let profile): "profile-" + profile.peer
        case .funding(let review): "funding-" + review.request.temporaryID.hex
        case .payment(let review): "payment-" + review.request.id.hex
        case .close(let review): "close-\(review.force)-" + review.channel.id.hex
        }
    }
}

struct LightningReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    let review: LightningReview
    var onConfirmed: () -> Void = {}
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                details
                Section {
                    Text("Regtest only · test coins have no value").font(.footnote)
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningReviewError") }
                    Button(busy ? "Confirming…" : "Confirm") { confirm() }
                        .disabled(busy).accessibilityIdentifier("lightningConfirm")
                }
            }
            .navigationTitle("Review Lightning")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(busy).accessibilityIdentifier("lightningCancel")
            } }
            .interactiveDismissDisabled(busy)
        }
    }
    @ViewBuilder private var details: some View {
        switch review {
        case .profile(let profile):
            Section("Provider") {
                LabeledContent("Name", value: profile.name)
                LabeledContent("Endpoint", value: profile.endpoint)
                Text(profile.peer).font(.caption.monospaced())
                Text("Automatic channel recovery returns funds to this wallet, with a maximum fee of 500 sats per recovery transaction. Opening and payments still require a separate review.")
            }
        case .funding(let review):
            Section("Channel funding") {
                LabeledContent("Capacity", value: "\(review.request.amountSat) sats")
                LabeledContent("On-chain fee", value: "\(review.preview.fee) sats")
                LabeledContent("Total", value: "\(Int64(review.request.amountSat) + review.preview.fee) sats")
                Text(review.preview.destination).font(.caption.monospaced())
                Text("Winnow reserves the reviewed wallet inputs. Once submitted, funding cannot be canceled merely because the peer disconnects.")
            }
        case .payment(let review):
            Section("Send payment") {
                LabeledContent("Amount", value: "\(review.request.amountMsat / 1000) sats")
                LabeledContent("Maximum fee", value: "\(review.request.feeLimitMsat / 1000) sats")
                LabeledContent("Maximum expiry", value: "\(review.request.maximumDelta) blocks")
                Text(review.offerText).font(.caption.monospaced()).textSelection(.enabled)
                Text("Funds may remain committed while the recipient is offline. “Awaiting recipient” means pending; only “Settled” confirms payment.")
            }
        case .close(let review):
            let force = review.force
            Section(force ? "Force close" : "Cooperative close") {
                Text(force ? "Publish the latest enforceable commitment. Returning funds may require a delay and additional recovery transactions." : "Ask the provider to close this channel and return funds to your Winnow wallet.")
                Text(force ? "The commitment fee is already fixed by the signed channel state. Recovery transactions use the approved 500-sat fee limit." : "The fee uses Winnow’s wallet fee policy and includes space for the provider’s closing output.")
                if !force {
                    LabeledContent("Maximum negotiated fee", value: "\(review.feeSat) sats")
                        .accessibilityIdentifier("lightningCloseMaximumFee")
                    LabeledContent("Return address") { Text(review.address).font(.caption.monospaced()) }
                }
            }
        }
    }
    private func confirm() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch review {
                case .profile(let profile): try await controller.saveProfile(profile, model: model)
                case .funding(let review): try await controller.fund(review, model: model)
                case .payment(let review): try await controller.pay(review, model: model)
                case .close(let review): try await controller.close(review, model: model)
                }
                onConfirmed()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
