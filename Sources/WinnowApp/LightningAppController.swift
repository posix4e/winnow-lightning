import CryptoKit
import Foundation
import LightningCore
import Observation
import WalletCore

@Observable @MainActor
final class LightningAppController {
    let network: BitcoinNetwork
    var networkNotice: String { network == .mainnet ? "Mainnet · real bitcoin" : "\(network.rawValue.capitalized) · test coins have no value" }
    private(set) var profile: LightningProfile?
    private(set) var nodeID = ""
    private(set) var channels: [LightningEngine.Channel] = []
    private(set) var balances: [LightningEngine.ChannelBalance] = []
    private(set) var payments: [LightningEngine.Payment] = []
    private(set) var funding: [LightningEngine.FundingRequest] = []
    private(set) var offers: [LightningEngine.ReceiveOffer] = []
    var invoiceCapacities: [LightningEngine.InvoiceCapacity] = []
    var liquidityQuote: LiquidityQuote?
    var liquidityInfo: LightningLiquidity.Info?
    var liquidityRequestInFlight = false
    var liquiditySession: LightningPeerSession? { session }
    private(set) var connection = "Waiting for verified chain"
    private(set) var peerWarning: String?
    private(set) var chainCurrent = false
    var error: String?
    private(set) var engine: LightningEngine?
    private(set) var driver: LightningChainDriver?
    @ObservationIgnored private var session: LightningPeerSession?
    @ObservationIgnored private let keys: any StoreKeyVault
    @ObservationIgnored private let backgroundKeys: any StoreKeyVault
    @ObservationIgnored private var backgroundStore: LightningBackgroundStore?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored var monitoringChanged: ((Bool) -> Void)?
    @ObservationIgnored var recoveryRelayFailed: (() -> Void)?
    @ObservationIgnored private(set) var generation: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var fixtureNodeSecret: Data?
    #endif
    static let recoveryFeeSat: UInt64 = 500
    static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }

    init(network: BitcoinNetwork, keys: any StoreKeyVault, backgroundKeys: (any StoreKeyVault)? = nil) {
        self.network = network; self.keys = keys; self.backgroundKeys = backgroundKeys ?? keys
    }

    private func openBackgroundStore(root: URL, create: Bool) throws -> LightningBackgroundStore {
        if let backgroundStore { return backgroundStore }
        let dir = root.appending(path: "lightning-background", directoryHint: .isDirectory)
        let account = "lightning-background-v1.\(network.rawValue)"
        let existing = try backgroundKeys.key(for: account)
        let hasJournal = FileManager.default.fileExists(atPath: dir.appending(path: "journal.v1").path)
        guard (existing != nil) == hasJournal, create || hasJournal else { throw LightningError.storageFailed }
        let key = try existing ?? backgroundKeys.establishKey(for: account)
        let store = try LightningBackgroundStore(directory: dir, key: key.withUnsafeBytes { Data($0) })
        backgroundStore = store
        return store
    }

    func prepareBackground(directory: URL) throws -> LightningBackgroundMonitor {
        try LightningBackgroundMonitor(store: openBackgroundStore(root: directory, create: false),
                                       chain: NetworkParams.params(for: network).genesisHash)
    }

    func requireNetwork(_ model: AppModel, generation expected: UInt64? = nil) throws {
        guard model.network == network, !model.changingNetwork,
              expected == nil || expected == generation else { throw CancellationError() }
    }

    func prepare(directory root: URL, headers: HeaderChain) async throws {
        guard await headers.params.genesisHash == NetworkParams.params(for: network).genesisHash else { throw LightningError.invalidHash }
        if engine == nil {
            let dir = root.appending(path: "lightning", directoryHint: .isDirectory)
            let account = network == .regtest ? "lightning-journal-v2" : "lightning-journal-v2.\(network.rawValue)"
            let existing = try keys.key(for: account)
            let hasJournal = FileManager.default.fileExists(atPath: dir.appending(path: "journal.v1").path)
            guard (existing != nil) == hasJournal else { throw LightningError.storageFailed }
            let key = try existing ?? keys.establishKey(for: account)
            let journal = try FileLightningJournal(directory: dir, key: key.withUnsafeBytes { Data($0) })
            #if DEBUG
            let nodeSecret = fixtureNodeSecret
            #else
            let nodeSecret: Data? = nil
            #endif
            let opened = try LightningEngine(chain: NetworkParams.params(for: network).genesisHash, nodeSecret: nodeSecret,
                journal: journal, backgroundStore: openBackgroundStore(root: root, create: true))
            directory = dir
            let loaded = try loadProfile() ?? LightningProviders.recommended(network: network)
            engine = opened; profile = loaded
            liquidityQuote = try loadLiquidityQuote()
        }
        guard let engine else { throw LightningError.storageFailed }
        try await engine.resumeFromBackground()
        try await engine.persistIdentity()
        try await engine.prepareInvoiceRouting()
        driver = LightningChainDriver(engine: engine, headers: headers)
        try await refresh()
    }
    private func loadProfile() throws -> LightningProfile? {
        guard let file = directory?.appending(path: "profile.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-profile", keys: keys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        return try LightningProfile.parse(String(decoding: sealed.payload, as: UTF8.self), network: network)
    }
    func saveProfile(_ proposed: LightningProfile, model: AppModel) async throws {
        try requireNetwork(model)
        try proposed.validate(network: network)
        guard let directory, let engine else { throw AppModel.AppError.noStack }
        guard liquidityQuote?.accepted != true || proposed == profile else { throw LightningError.invalidState }
        if let current = profile, current.peerKey != proposed.peerKey {
            guard await engine.channels().allSatisfy({ $0.phase == .closed }),
                  liquidityQuote?.accepted != true else { throw LightningError.invalidState }
        }
        let epoch = generation
        try await model.authenticateSensitiveAction(reason: "Approve this \(network.rawValue) Lightning provider and recovery policy")
        defer { model.keychainAuthentication.revoke() }
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        let sameEndpoint = profile?.peer == proposed.peer && profile?.host == proposed.host && profile?.port == proposed.port
        // Drop only an unapproved stale quote before changing its binding.
        // A crash between these writes retains the old valid provider.
        if profile != proposed { try storeLiquidityQuote(nil); liquidityQuote = nil; liquidityInfo = nil }
        try StoreSeal(store: "lightning-profile", keys: keys).write(JSONEncoder().encode(proposed), network: network,
            to: directory.appending(path: "profile.json")) { data, file in
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
        // Receiving-path or fee updates do not change the authenticated TCP
        // peer. Keep that session while the new profile becomes durable.
        if !sameEndpoint { await stop() }
        profile = proposed
        try requireNetwork(model)
        await model.syncNow()
        await resume(model: model)
    }
    func stop() async {
        generation &+= 1
        let previous = session; session = nil
        await engine?.chainDisconnected(); await previous?.stop()
        chainCurrent = false; connection = "Paused"
    }
    func resume(model: AppModel) async {
        do {
            let epoch = generation
            try requireNetwork(model)
            try await refresh()
            try requireNetwork(model, generation: epoch)
            model.e2e?.journal("lightning.resume", fields: ["connection": connection, "connecting": String(connecting), "chainCurrent": String(chainCurrent)])
            guard chainCurrent, let engine, let profile, !connecting else { return }
            if await session?.status == .connected {
                try await resumeSubmittedFunding(model: model)
                try await session?.flush()
                return
            }
            connecting = true; defer { connecting = false }
            let next = LightningPeerSession(engine: engine, peer: profile.peerKey, host: profile.host, port: profile.port) { [weak self, weak model] events in
                guard let self, let model else { throw CancellationError() }
                try await self.requireNetwork(model, generation: epoch)
                try await self.handle(events, model: model)
            }
            session = next
            try await next.start()
            guard epoch == generation else { await next.stop(); return }
            try await configureRecovery(model: model)
            try await resumeSubmittedFunding(model: model)
            try await refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription; try? await refresh()
            model.e2e?.journal("lightning.connectionFailed", fields: ["error": String(describing: error)])
        }
    }
    func refresh() async throws {
        guard let engine else { return }
        nodeID = try await engine.nodeID().hex
        channels = await engine.channels(); payments = await engine.payments()
        monitoringChanged?(channels.contains(where: \.needsMonitoring))
        balances = try await engine.channelBalances(); funding = try await engine.fundingRequests()
        offers = try await engine.receiveOffers(now: Self.now)
        if let profile { invoiceCapacities = try await engine.invoiceCapacities(peer: profile.peerKey) }
        else { invoiceCapacities = [] }
        chainCurrent = await engine.isChainCurrent()
        switch await session?.status {
        case .connected: connection = chainCurrent ? "Connected" : "Verifying chain"
        case .connecting: connection = "Connecting"
        case .failed(let reason): connection = "Disconnected: \(reason)"
        default: connection = chainCurrent ? "Ready to connect" : "Waiting for verified chain"
        }
        peerWarning = await session?.lastPeerWarning
    }
    func handle(_ events: [LightningEngine.Event], model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard let stack = model.stack, let wallet = model.wallet else { throw AppModel.AppError.noStack }
        for event in events {
            try requireNetwork(model, generation: epoch)
            switch event {
            case .broadcastFunding(_, let raw):
                guard let reservation = await wallet.fundingReservations.first(where: { $0.rawTransaction == raw }) else {
                    throw LightningError.storageFailed
                }
                try requireNetwork(model, generation: epoch)
                _ = try await stack.broadcaster.broadcast(raw, feeRateSatPerVByte: reservation.feeRateSatPerVByte)
                try await wallet.commitFundingBroadcast(requestID: reservation.requestID, rawTransaction: raw)
            case .broadcastClose, .broadcastRecovery:
                do { try await relayBackgroundRecovery([event], broadcaster: stack.broadcaster) }
                catch { recoveryRelayFailed?(); throw error }
            case .channelReady: try await configureRecovery(model: model)
            case .fundingRequired, .paymentChanged: break
            }
        }
        try await refresh()
    }
    private func configureRecovery(model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard profile != nil, let engine, let wallet = model.wallet else { return }
        let needingRecovery = Set(try await engine.channelsNeedingRecoveryConfiguration())
        for channel in await engine.channels() where needingRecovery.contains(channel.id) {
            let address = try await wallet.freshReceiveAddress()
            try requireNetwork(model, generation: epoch)
            let destination = try AddressDecoder.scriptPubKey(for: address, network: network)
            try await engine.configureRecovery(channelID: channel.id, peer: channel.peer, destination: destination, feeSat: Self.recoveryFeeSat)
        }
    }
    func loadLiquidityQuote() throws -> LiquidityQuote? {
        guard let file = directory?.appending(path: "liquidity.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-liquidity", keys: keys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        let quote = try JSONDecoder().decode(LiquidityQuote.self, from: sealed.payload)
        guard quote.profile == profile else { throw LightningError.storageFailed }
        return quote
    }
    func storeLiquidityQuote(_ quote: LiquidityQuote?) throws {
        guard let file = directory?.appending(path: "liquidity.json") else { throw LightningError.storageFailed }
        if let quote {
            try StoreSeal(store: "lightning-liquidity", keys: keys).write(JSONEncoder().encode(quote), network: network, to: file) { data, path in
                try data.write(to: path, options: [.atomic, .completeFileProtection])
            }
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
