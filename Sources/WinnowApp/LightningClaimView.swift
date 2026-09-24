#if WINNOW_LIGHTNING_RESEARCH
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LightningCore

struct LightningClaimView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let defaultHost: String
    let defaultPort: String
    @State private var provider = ""
    @State private var amount = "5000"
    @State private var incoming = ""
    @State private var error: String?
    @State private var busy = false
    @State private var showImport = false
    @State private var share: ShareItem?
    private struct ShareItem: Identifiable { let id = UUID(); let items: [Any] }
    private var controller: LightningController { model.lightning }
    private var claims: [LightningClaim] {
        (controller.snapshot?.claims.values.map { $0 } ?? []).sorted { $0.claim_id < $1.claim_id }
    }

    var body: some View {
        if controller.engine == nil {
            ContentUnavailableView {
                Label("Lightning is locked", systemImage: "lock")
            } description: {
                Text(error ?? "Unlock to resume your saved claims after returning to Winnow.")
            } actions: {
                Button("Unlock Lightning") { run { try await controller.start(model) } }
                    .disabled(busy).accessibilityIdentifier("unlockClaimSessionButton")
            }
            .navigationTitle("Message payments")
        } else {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        Text("Regtest only. Anyone with a copy can claim first, including the sender. Sharing does not confirm receipt. Keep the recipient and provider online until payment settles.")
                            .font(.footnote)
                        if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("claimError") }
                    }
                    Section("Send by message") {
                        Picker("Provider", selection: $provider) {
                            Text("Choose a connected provider").tag("")
                            ForEach(controller.snapshot?.peers ?? [], id: \.self) { peer in
                                Text("\(peer.prefix(16))…").tag(peer)
                            }
                        }
                        TextField("Recipient amount (sats)", text: $amount)
                            .keyboardType(.numberPad).accessibilityIdentifier("claimAmount")
                        Text("Provider address: \(defaultHost):\(defaultPort)").font(.caption)
                        Button("Get claim quote") {
                            run {
                                guard let sats = UInt64(amount), (5000...100000).contains(sats),
                                      let port = UInt16(defaultPort), port > 0, !provider.isEmpty else {
                                    throw LightningError.invalidResponse
                                }
                                try await controller.prepareClaim(provider: provider, host: defaultHost,
                                    port: port, amountMsat: sats * 1000)
                            }
                        }
                        .accessibilityIdentifier("prepareClaimButton")
                    }
                    Section("Receive a claim") {
                        SecureField("Claim text", text: $incoming)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .accessibilityLabel("Claim text")
                        Button("Paste claim") { incoming = model.pasteboardText() ?? "" }
                            .accessibilityIdentifier("pasteClaimButton")
                        Button("Import claim file") { showImport = true }
                        Button("Review claim") {
                            run {
                                try await controller.importClaim(incoming.trimmingCharacters(in: .whitespacesAndNewlines))
                                incoming = ""
                            }
                        }
                        .accessibilityIdentifier("importClaimButton")
                    }
                    ForEach(claims, id: \.claim_id) { claim in
                        Section(claim.direction == "sent" ? "Sending \(claim.amount_msat / 1000) sats" : "Receiving \(claim.amount_msat / 1000) sats") {
                            Text(label(claim.state)).accessibilityIdentifier("claimState-\(claim.claim_id)")
                            if let issue = claim.last_error {
                                Text(issue == "already_bound" ? "Provider reports this claim is already bound to another invoice."
                                     : issue == "expired" ? "Provider reports this claim has expired."
                                     : "Provider rejected this request. Check its setup before retrying.")
                                    .foregroundStyle(.red)
                            }
                            if let terms = claim.terms {
                                Text("Provider fee: \(terms.fee_msat / 1000) sats")
                                if claim.direction == "sent" {
                                    Text("Total on success: \((terms.amount_msat + terms.fee_msat) / 1000) sats")
                                }
                                Text("New claims end at block \(terms.latest_claim_height) or \(Date(timeIntervalSince1970: Double(terms.expires_at_unix)).formatted()), whichever comes first.")
                                    .font(.footnote)
                            }
                            if claim.state == "quoted" {
                                Text("Funds remain committed until payment settles or the channel resolves the timeout. There is no early cancellation after committing.")
                                    .font(.footnote)
                                Button("Commit this amount") { run { try await controller.commitClaim(claim, model: model) } }
                                    .accessibilityIdentifier("commitClaimButton")
                            }
                            if claim.state == "preparing" || claim.state == "quoted" {
                                Button("Discard unfunded quote", role: .destructive) {
                                    run { try await controller.cancelClaim(claim) }
                                }
                            }
                            if claim.state == "awaiting_claim" {
                                Button("Share claim") {
                                    run { share = ShareItem(items: [try await controller.exportClaim(claim, model: model)]) }
                                }
                                .accessibilityIdentifier("shareClaimButton")
                                Button("Copy claim for two minutes") {
                                    run {
                                        let text = try await controller.exportClaim(claim, model: model)
                                        ClipboardPolicy.fundedClaim.apply(text)
                                    }
                                }
                                .accessibilityIdentifier("copyClaimButton")
                                Button("Share claim as a file") {
                                    run {
                                        let text = try await controller.exportClaim(claim, model: model)
                                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-claims", isDirectory: true)
                                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
                                        let file = directory.appendingPathComponent("\(claim.claim_id).wlnclaim")
                                        try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtection])
                                        share = ShareItem(items: [file])
                                    }
                                }
                                Text("Use a file if your messenger limits message length. Re-sharing uses the same claim.").font(.footnote)
                            }
                            if claim.state == "ready" || claim.state == "claiming" {
                                Button(claim.state == "ready" ? "Claim payment" : "Reconnect and check claim") {
                                    run { try await controller.redeemClaim(claim) }
                                }
                                .accessibilityIdentifier("redeemClaimButton")
                            }
                            if claim.state == "claiming" {
                                Text("Pending. This amount is not received until your channel confirms settlement.").font(.footnote)
                            }
                        }
                        .id(claim.claim_id)
                    }
                }
                .onChange(of: claims.map(\.claim_id)) { old, current in
                    if let added = current.first(where: { !old.contains($0) }) {
                        withAnimation { proxy.scrollTo(added, anchor: .top) }
                    }
                }
                .navigationTitle("Message payments")
                .disabled(busy || controller.snapshot?.chain_ready != true)
                .onAppear {
                    cleanSharedFiles()
                    if provider.isEmpty, let first = controller.snapshot?.peers.first { provider = first }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { incoming = "" }
                }
                .sheet(item: $share, onDismiss: cleanSharedFiles) { item in
                    ClaimActivitySheet(items: item.items, completed: { share = nil; cleanSharedFiles() })
                }
                .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .data]) { result in
                    run {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        guard let size, size <= 32_768 else { throw LightningError.invalidResponse }
                        let bytes = try Data(contentsOf: url)
                        guard bytes.count <= 32_768, let text = String(data: bytes, encoding: .utf8) else {
                            throw LightningError.invalidResponse
                        }
                        try await controller.importClaim(text)
                    }
                }
            }
        }
    }

    private func cleanSharedFiles() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("winnow-claims", isDirectory: true))
    }

    private func label(_ state: String) -> String {
        switch state {
        case "preparing": "Requesting quote"
        case "quoted": "Review before committing"
        case "cancelling": "Discarding unfunded quote"
        case "committing", "funding": "Committing funds"
        case "awaiting_claim": "Funded · awaiting claim"
        case "paid": "Payment settled"
        case "failed": "Payment failed · check channel recovery"
        case "expired_pending": "Expired · funds awaiting channel resolution"
        case "expired": "Claim expired"
        case "ready": "Verified · ready to claim"
        case "claiming": "Claiming · awaiting settlement"
        case "received": "Payment received"
        default: "Checking payment state"
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ClaimActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let completed: @MainActor () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completed() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
