import SwiftUI
import UIKit
import Combine
import LDKNode

@main
struct WinnowLightningApp: App {
    @StateObject private var model = LightningModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Color(red: 0.17, green: 0.72, blue: 0.64))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.pauseForBackground() }
                    if phase == .active { model.resumeIfNeeded() }
                }
        }
    }
}

@MainActor
final class LightningModel: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "esplora") ?? ""
    @Published var listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "0.0.0.0:9735"
    @Published var announceAddress = UserDefaults.standard.string(forKey: "announceAddress") ?? ""
    @Published var peerNodeID = UserDefaults.standard.string(forKey: "peerNodeID") ?? ""
    @Published var peerAddress = UserDefaults.standard.string(forKey: "peerAddress") ?? ""
    @Published var peerKEM = UserDefaults.standard.string(forKey: "peerKEM") ?? ""
    @Published var peerSigning = UserDefaults.standard.string(forKey: "peerSigning") ?? ""
    @Published var snapshot: LightningSnapshot?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var latestInvoice = ""
    @Published var notice = ""

    private let engine = LightningEngine()
    private var shouldRun = false
    private var wasBackgrounded = false
    private var savedPins: [PeerPin] {
        guard let data = UserDefaults.standard.data(forKey: "pinnedPeers") else { return [] }
        return (try? JSONDecoder().decode([PeerPin].self, from: data)) ?? []
    }

    var peer: PeerConfiguration {
        PeerConfiguration(nodeID: peerNodeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                          address: peerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                          kemHex: peerKEM, signingHex: peerSigning)
    }

    func start() {
        saveSettings()
        shouldRun = true
        isBusy = true
        notice = "Starting regtest node…"
        engine.start(server: server, listenAddress: listenAddress,
                     announceAddress: announceAddress, peer: peer, savedPins: savedPins) { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.apply(result)
                if case .failure = result { self.shouldRun = false }
                if case .success = result { self.notice = "Regtest node running" }
            }
        }
    }

    func stop() {
        shouldRun = false
        wasBackgrounded = false
        isBusy = true
        engine.stop { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.snapshot = nil
                if case let .failure(error) = result { self.errorMessage = error.localizedDescription }
                self.notice = "Node stopped"
            }
        }
    }

    func pauseForBackground() {
        guard shouldRun else { return }
        wasBackgrounded = true
        engine.stop { _ in
            DispatchQueue.main.async { self.snapshot = nil; self.notice = "Paused in background" }
        }
    }

    func resumeIfNeeded() {
        if shouldRun && wasBackgrounded {
            wasBackgrounded = false
            start()
        }
    }

    func refresh() {
        guard snapshot != nil, !isBusy else { return }
        engine.refresh { result in DispatchQueue.main.async { self.apply(result, alert: false) } }
    }

    func sync() {
        isBusy = true
        engine.sync { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.apply(result)
                if case .success = result { self.notice = "Wallet synced" }
            }
        }
    }

    func connect() {
        saveSettings()
        isBusy = true
        let connectingPeer = peer
        engine.connect(peer: connectingPeer, savedPins: savedPins) { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.apply(result)
                if case .success = result {
                    self.notice = "Pinned peer connected"
                }
            }
        }
    }

    func openChannel(sats: UInt64, announced: Bool) {
        isBusy = true
        engine.openChannel(peer: peer, sats: sats, announced: announced) { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.apply(result)
                if case .success = result { self.notice = "Channel opening requested" }
            }
        }
    }

    func makeInvoice(msat: UInt64, memo: String) {
        isBusy = true
        engine.invoice(msat: msat, memo: memo) { result in
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case let .success(invoice): self.latestInvoice = invoice; self.notice = "Invoice ready"
                case let .failure(error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func pay(invoice: String) {
        isBusy = true
        engine.pay(invoice: invoice, trustedSigningHex: peerSigning) { result in
            DispatchQueue.main.async {
                self.isBusy = false
                self.apply(result)
                if case .success = result { self.notice = "Verified payment started" }
            }
        }
    }

    private func apply(_ result: Result<LightningSnapshot, Error>, alert: Bool = true) {
        switch result {
        case let .success(snapshot): self.snapshot = snapshot
        case let .failure(error): if alert { self.errorMessage = error.localizedDescription }
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(server, forKey: "esplora")
        defaults.set(listenAddress, forKey: "listenAddress")
        defaults.set(announceAddress, forKey: "announceAddress")
        defaults.set(peerNodeID, forKey: "peerNodeID")
        defaults.set(peerAddress, forKey: "peerAddress")
        defaults.set(peerKEM, forKey: "peerKEM")
        defaults.set(peerSigning, forKey: "peerSigning")
    }
}

private enum Palette {
    static let background = Color(red: 0.06, green: 0.11, blue: 0.20)
    static let card = Color(red: 0.11, green: 0.19, blue: 0.30)
    static let muted = Color(red: 0.58, green: 0.68, blue: 0.75)
    static let mint = Color(red: 0.38, green: 0.83, blue: 0.75)
}

struct RootView: View {
    @EnvironmentObject private var model: LightningModel

    var body: some View {
        TabView {
            NavigationStack { WalletView() }
                .tabItem { Label("Wallet", systemImage: "bolt.circle.fill") }
            NavigationStack { PeerView() }
                .tabItem { Label("Peer", systemImage: "point.3.connected.trianglepath.dotted") }
            NavigationStack { PaymentsView() }
                .tabItem { Label("Payments", systemImage: "arrow.left.arrow.right") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
        }
        .preferredColorScheme(.dark)
        .alert("Winnow Lightning", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct CopyValue: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(value.isEmpty ? "Start the node to view" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .textSelection(.enabled)
            if !value.isEmpty {
                Button { UIPasteboard.general.string = value } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

private struct WalletView: View {
    @EnvironmentObject private var model: LightningModel
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PQLN / REGTEST").font(.caption.weight(.bold)).tracking(2).foregroundStyle(Palette.mint)
                    Text("Lightning, in a lab.").font(.largeTitle.bold())
                    Text("A light client using an Esplora server and pinned quantum-resistant peer keys.")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }.padding(.vertical, 8)

                Card {
                    HStack {
                        Circle().fill(model.snapshot == nil ? .orange : Palette.mint).frame(width: 10, height: 10)
                        Text(model.snapshot == nil ? "Node stopped" : "Node running").font(.headline)
                        Spacer()
                        if model.isBusy { ProgressView() }
                    }
                    Text(model.notice.isEmpty ? "Enter a regtest Esplora URL in Setup, then start." : model.notice)
                        .font(.footnote).foregroundStyle(Palette.muted)
                    Button(model.snapshot == nil ? "Start node" : "Stop node") {
                        model.snapshot == nil ? model.start() : model.stop()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }

                HStack(spacing: 12) {
                    Card {
                        Text("ON CHAIN").font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
                        Text("\(model.snapshot?.onchainSats ?? 0)").font(.title2.bold())
                        Text("sats spendable").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Card {
                        Text("LIGHTNING").font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
                        Text("\(model.snapshot?.lightningSats ?? 0)").font(.title2.bold())
                        Text("sats claimable").font(.caption).foregroundStyle(Palette.muted)
                    }
                }

                Card {
                    Text("Funding address").font(.headline)
                    CopyValue(title: "REGTEST ONLY", value: model.snapshot?.address ?? "")
                    Button("Sync wallet") { model.sync() }
                        .buttonStyle(.bordered).disabled(model.snapshot == nil || model.isBusy)
                }

                Card {
                    Text("Recent activity").font(.headline)
                    if model.snapshot?.events.isEmpty != false {
                        Text("No Lightning events yet.").font(.subheadline).foregroundStyle(Palette.muted)
                    } else {
                        ForEach(model.snapshot!.events, id: \.self) { event in
                            Text(event).font(.subheadline)
                        }
                    }
                }

                Text("Research build · regtest coins only · keep the app open while testing channels and payments.")
                    .font(.footnote).foregroundStyle(Palette.muted).padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Palette.background)
        .navigationTitle("Winnow Lightning")
        .onReceive(timer) { _ in model.refresh() }
    }
}

private struct PeerView: View {
    @EnvironmentObject private var model: LightningModel
    @State private var channelSats = "100000"
    @State private var announced = false
    @State private var confirmOpen = false

    var body: some View {
        Form {
            Section("Your identity") {
                CopyValue(title: "NODE ID", value: model.snapshot?.nodeID ?? "")
                CopyValue(title: "ML-KEM PUBLIC KEY", value: model.snapshot?.kemKey ?? "")
                CopyValue(title: "ML-DSA PUBLIC KEY", value: model.snapshot?.signingKey ?? "")
            }
            Section("Pin a peer") {
                TextField("Peer node ID", text: $model.peerNodeID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Peer address, e.g. 192.168.1.8:9735", text: $model.peerAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("ML-KEM public key (hex)", text: $model.peerKEM, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("ML-DSA public key (hex)", text: $model.peerSigning, axis: .vertical)
                    .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Compare the peer keys through a trusted channel before connecting or paying.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Connect pinned peer") { model.connect() }
                    .disabled(model.snapshot == nil || model.isBusy || !model.peer.isComplete)
            }
            Section("Open a channel") {
                TextField("Amount in sats", text: $channelSats).keyboardType(.numberPad)
                Toggle("Announce channel for PQ routing", isOn: $announced)
                if announced {
                    Text("Requires a reachable announcement address in Setup and a phone that stays online during the test.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Open channel") { confirmOpen = true }
                    .disabled(model.snapshot == nil || model.isBusy || !model.peer.isComplete || UInt64(channelSats) == nil || (announced && model.announceAddress.isEmpty))
            }
            Section("Channels") {
                if model.snapshot?.channels.isEmpty != false {
                    Text("No channels yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot!.channels) { channel in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(channel.ready ? "Ready" : "Pending").font(.headline)
                            Text("\(channel.amountSats) sats · out \(channel.outboundSats) · in \(channel.inboundSats)")
                            Text(channel.peer).font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                }
            }
        }
        .navigationTitle("PQLN peer")
        .confirmationDialog("Open a \(channelSats) sat regtest channel?", isPresented: $confirmOpen) {
            Button("Open channel") { if let sats = UInt64(channelSats) { model.openChannel(sats: sats, announced: announced) } }
        }
    }
}

private struct PaymentsView: View {
    @EnvironmentObject private var model: LightningModel
    @State private var amountMsat = "1000"
    @State private var memo = "Winnow Lightning test"
    @State private var invoiceToPay = ""
    @State private var confirmPay = false
    @State private var paymentSummary = ""

    var body: some View {
        Form {
            Section("Receive") {
                TextField("Amount in millisats", text: $amountMsat).keyboardType(.numberPad)
                TextField("Description", text: $memo)
                Button("Create PQLN invoice") {
                    if let amount = UInt64(amountMsat) { model.makeInvoice(msat: amount, memo: memo) }
                }
                .disabled(model.snapshot == nil || model.isBusy || UInt64(amountMsat) == nil)
                if !model.latestInvoice.isEmpty {
                    Text(model.latestInvoice).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy invoice") { UIPasteboard.general.string = model.latestInvoice }
                }
            }
            Section("Pay") {
                TextEditor(text: $invoiceToPay).frame(minHeight: 100)
                Button("Paste invoice") { invoiceToPay = UIPasteboard.general.string ?? "" }
                Text("The app requires a regtest invoice signed by the ML-DSA key pinned on the Peer tab. A plain Lightning invoice is rejected.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Verify and pay") {
                    do {
                        let invoice = try Bolt11Invoice.fromStr(invoiceStr: invoiceToPay.trimmingCharacters(in: .whitespacesAndNewlines))
                        guard let amount = invoice.amountMilliSatoshis(), amount > 0 else {
                            model.errorMessage = "This research app needs an invoice with a fixed amount."
                            return
                        }
                        paymentSummary = "Verify the pinned ML-DSA key and pay \(amount) millisats on regtest?"
                        confirmPay = true
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
                    .disabled(model.snapshot == nil || model.isBusy || invoiceToPay.isEmpty || model.peerSigning.isEmpty)
            }
        }
        .navigationTitle("Payments")
        .confirmationDialog(paymentSummary, isPresented: $confirmPay) {
            Button("Verify and pay") { model.pay(invoice: invoiceToPay) }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: LightningModel

    var body: some View {
        Form {
            Section("Chain source") {
                TextField("http://your-regtest-esplora:3002", text: $model.server)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("The phone connects directly to your Esplora server. Use an address reachable from the phone; localhost points to the phone itself.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("An HTTP server can observe wallet queries and those requests are unencrypted. Use a trusted local server or HTTPS.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Start with this server") { model.start() }.disabled(model.isBusy)
            }
            Section("Peer reachability") {
                TextField("Listen address", text: $model.listenAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Announce address (optional)", text: $model.announceAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("For an announced regtest channel, use this phone's reachable LAN address and port. Restart the node after changing these addresses.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About this build") {
                LabeledContent("Network", value: "Bitcoin regtest")
                LabeledContent("Node", value: "LDK + PQLN")
                Text("The 64-byte node seed is stored in this device's Keychain. Deleting the app or losing the device may make the regtest node unrecoverable.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("This experiment adds quantum-resistant peer messages and invoice signatures. Channel funds and Bitcoin's on-chain signatures are not quantum safe.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("iOS pauses the node when the app is in the background. There is no watchtower in this build.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Setup")
    }
}
