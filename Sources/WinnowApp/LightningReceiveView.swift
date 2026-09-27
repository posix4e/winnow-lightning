import LightningCore
import SwiftUI
import WalletCore

struct LightningReceiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    var useBitcoin: (() -> Void)?
    @State private var amount = ""
    @State private var invoice: String?
    @State private var invoiceExpiry: Date?
    @State private var invoiceHash: Data?
    @State private var setup = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(controller.networkNotice).font(.footnote)
                    LabeledContent("Provider", value: controller.profile?.name ?? "Choose a provider")
                        .accessibilityIdentifier("lightningReceiveProvider").accessibilityValue(controller.profile?.name ?? "Choose a provider")
                    LabeledContent("Connection", value: controller.connection)
                    LabeledContent("Can receive", value: "\(controller.maximumReceivableSat) sats")
                        .accessibilityIdentifier("lightningReceivable")
                }
                if let invoice, let invoiceExpiry {
                    invoiceSection(invoice, expires: invoiceExpiry)
                } else if controller.maximumReceivableSat > 0 {
                    Section("Lightning invoice") {
                        TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                            .accessibilityIdentifier("lightningReceiveAmount")
                        Button("Create Lightning invoice") { run {
                            guard let sats = UInt64(amount), sats > 0 else { throw LightningError.invalidAmount }
                            let created = try await controller.createReceiveInvoice(amountSat: sats, model: model)
                            let decoded = try Bolt11Invoice.decode(created, network: controller.network)
                            invoice = created; invoiceHash = decoded.paymentHash
                            invoiceExpiry = Date(timeIntervalSince1970: TimeInterval(decoded.expiresAt))
                        } }.accessibilityIdentifier("lightningCreateInvoice")
                    }
                } else {
                    Section("Set up Lightning receiving") {
                        Text("Your wallet needs receiving capacity before it can accept a Lightning payment. Setup may have a one-time fee.")
                        if controller.channels.contains(where: { $0.phase != .closed }) {
                            Text("Waiting for a confirmed channel and its receiving policy. Keep Winnow open and sync to check progress.")
                        }
                        NavigationLink("Get receiving capacity") { LightningLiquidityView(controller: controller) }
                            .disabled(controller.profile?.liquidityProvider == nil)
                            .accessibilityIdentifier("lightningGetCapacity")
                        Button("Choose provider") { setup = true }.accessibilityIdentifier("lightningReceiveSetup")
                    }
                }
                Section {
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningReceiveError") }
                    Button("Sync and reconnect") { run { await model.syncNow(); await controller.resume(model: model) } }
                        .accessibilityIdentifier("lightningReceiveReconnect")
                    Text("Use a Lightning invoice for Kraken's Lightning withdrawal. A Bitcoin address belongs in a Bitcoin withdrawal.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Keep Winnow open while receiving this invoice. It is a single-use invoice; offline async offers are available in Advanced mode.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let useBitcoin { Button("Receive Bitcoin instead", action: useBitcoin) }
                }
            }
            .navigationTitle("Receive Lightning")
            .disabled(busy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $setup) { LightningSetupView(controller: controller) }
            .task {
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { self.error = error.localizedDescription; return }
                }
            }
        }
    }
    private func invoiceSection(_ invoice: String, expires: Date) -> some View {
        Section("Lightning invoice · \(controller.network.rawValue)") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let received = controller.payments.contains { $0.hash == invoiceHash && $0.phase == .settled }
                if received { Text("Payment received").accessibilityIdentifier("lightningInvoicePaid") }
                else if context.date >= expires { Text("Invoice expired. Create a new invoice.") }
                else { payableInvoice(invoice, expires: expires) }
            }
            Button("New Lightning invoice") { self.invoice = nil; invoiceExpiry = nil; invoiceHash = nil }
        }
    }
    private func payableInvoice(_ invoice: String, expires: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            QRCodeView(content: invoice.uppercased()).frame(width: 240, height: 240)
                .frame(maxWidth: .infinity)
            Text(invoice).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                .accessibilityIdentifier("lightningReceiveInvoice").accessibilityValue(invoice)
            Text("Expires \(expires.formatted())").font(.caption)
            Button("Copy Lightning invoice") { ClipboardPolicy.interchange.apply(invoice) }
                .accessibilityIdentifier("lightningCopyInvoice")
            ShareLink("Share Lightning invoice", item: invoice).accessibilityIdentifier("lightningShareInvoice")
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
