#if WINNOW_LIGHTNING_RESEARCH
import SwiftUI
import LightningCore

struct LightningView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var error: String?
    @State private var peerCard = ""
    @State private var host = "127.0.0.1"
    @State private var port = "9735"
    @State private var capacity = "100000"
    @State private var invoice = ""
    @State private var amount = "2000000"
    @State private var maxFee = "1000"
    @State private var receivedInvoice = ""
    @State private var forceClose: LightningChannel?
    @State private var fundingReview: FundingReview?
    private struct FundingReview { let id: String; let request: LightningEvent; let fee: Int64 }

    private var controller: LightningController { model.lightning }
    var body: some View {
        Form {
            Section {
                Text("Regtest coins only. Keep Winnow open to monitor channels. Channel files stay on this device; a seed backup cannot restore them.")
                    .font(.footnote)
                if controller.engine == nil {
                    Button("Unlock Lightning") { run { try await controller.start(model) } }
                } else {
                    Text(controller.snapshot?.chain_ready == true ? "Channel scan caught up" : "Catching up through Winnow…")
                    Button("Lock Lightning") { run { await controller.stop() } }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let notice = controller.notice { Text(notice).foregroundStyle(.secondary) }
            }
            if controller.engine != nil {
                Section("Peer") {
                    ShareLink("Share my public peer card", item: controller.identityCard)
                    TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextEditor(text: $peerCard).frame(minHeight: 80).font(.caption.monospaced())
                    Text("Paste the peer card obtained directly from the person operating this peer. Its PQ keys will be pinned.").font(.footnote)
                    Button("Pin keys and connect") {
                        run {
                            guard let number = UInt16(port), number > 0 else { throw LightningError.invalidResponse }
                            try await controller.connect(card: peerCard, host: host, port: number)
                        }
                    }
                    TextField("Channel capacity (sats)", text: $capacity).keyboardType(.numberPad)
                    ForEach(controller.snapshot?.peers ?? [], id: \.self) { peer in
                        Button("Open channel to \(peer.prefix(12))…") {
                            run {
                                guard let sats = UInt64(capacity) else { throw LightningError.invalidResponse }
                                try await controller.openChannel(nodeID: peer, amount: sats)
                            }
                        }
                    }
                }
                Section("Funding requests") {
                    ForEach((controller.snapshot?.events ?? [:]).keys.sorted(), id: \.self) { id in
                        if let request = controller.snapshot?.events[id], request.kind == "funding" {
                            Text("Peer \(request.node_id?.prefix(16) ?? "")…").font(.caption.monospaced())
                            Text("Winnow selects and signs the inputs at \(controller.feeRate.formatted()) sat/vB. The channel protocol authorizes their relay.").font(.footnote)
                            Button("Fund \(request.amount_sat ?? 0) sats from Winnow") {
                                run {
                                    fundingReview = try await FundingReview(id: id, request: request,
                                        fee: controller.fundingFee(request: request, model: model))
                                }
                            }
                        }
                    }
                }
                Section("Payments") {
                    TextField("Amount (millisats)", text: $amount).keyboardType(.numberPad)
                    Button("Create invoice") {
                        run {
                            guard let value = UInt64(amount) else { throw LightningError.invalidResponse }
                            receivedInvoice = try await controller.receive(amountMsat: value)
                        }
                    }
                    if !receivedInvoice.isEmpty { ShareLink("Share invoice", item: receivedInvoice) }
                    TextEditor(text: $invoice).frame(minHeight: 70).font(.caption.monospaced())
                    TextField("Maximum routing fee (millisats)", text: $maxFee).keyboardType(.numberPad)
                    Button("Pay the entered amount") {
                        run {
                            guard let value = UInt64(amount), let fee = UInt64(maxFee) else { throw LightningError.invalidResponse }
                            try await controller.pay(invoice: invoice.trimmingCharacters(in: .whitespacesAndNewlines),
                                amountMsat: value, maxFeeMsat: fee, model: model)
                        }
                    }
                    ForEach((controller.snapshot?.payments ?? [:]).keys.sorted(), id: \.self) { id in
                        if let payment = controller.snapshot?.payments[id] {
                            Text("\(payment.amount_msat) millisats · \(payment.state)")
                        }
                    }
                }
                Section("Channels") {
                    ForEach(controller.snapshot?.channels ?? [], id: \.channel_id) { channel in
                        Text("\(channel.amount_sat) sats · \(channel.usable ? "Ready" : "Pending")")
                        Button("Close into Winnow") { run { try await controller.close(channel, force: false, model: model) } }
                        Button("Force close…", role: .destructive) { forceClose = channel }
                    }
                    ForEach((controller.snapshot?.events ?? [:]).keys.sorted(), id: \.self) { id in
                        if let event = controller.snapshot?.events[id], event.kind == "sweep_required" {
                            Button("Recover mature channel output into Winnow") {
                                run { try await controller.sweep(event, model: model) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Lightning")
        .disabled(busy || controller.starting)
        .confirmationDialog("Fund \(fundingReview?.request.amount_sat ?? 0) sats plus \(fundingReview?.fee ?? 0) sats fee?",
            isPresented: Binding(get: { fundingReview != nil }, set: { if !$0 { fundingReview = nil } })) {
                Button("Sign and reserve funding") {
                    guard let review = fundingReview else { return }
                    fundingReview = nil
                    run { try await controller.fund(eventID: review.id, request: review.request, reviewedFee: review.fee, model: model) }
                }
            }
        .confirmationDialog("Force close this channel? Its on-chain recovery may require waiting for the channel delay.",
            isPresented: Binding(get: { forceClose != nil }, set: { if !$0 { forceClose = nil } })) {
                Button("Force close", role: .destructive) {
                    guard let channel = forceClose else { return }
                    forceClose = nil
                    run { try await controller.close(channel, force: true, model: model) }
                }
            }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
#endif
