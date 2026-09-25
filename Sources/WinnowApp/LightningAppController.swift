import CryptoKit
import Foundation
import LightningCore
import Observation
import WalletCore

@Observable @MainActor
final class LightningAppController {
    private(set) var profile: LightningProfile?
    private(set) var nodeID = ""
    private(set) var channels: [LightningEngine.Channel] = []
    private(set) var balances: [LightningEngine.ChannelBalance] = []
    private(set) var payments: [LightningEngine.Payment] = []
    private(set) var funding: [LightningEngine.FundingRequest] = []
    private(set) var offers: [LightningEngine.ReceiveOffer] = []
    private(set) var connection = "Waiting for verified chain"
    private(set) var chainCurrent = false
    var error: String?
    private(set) var engine: LightningEngine?
    private(set) var driver: LightningChainDriver?
    @ObservationIgnored private var session: LightningPeerSession?
    @ObservationIgnored private let keys: any StoreKeyVault
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var generation: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var fixtureNodeSecret: Data?
    #endif
    static let recoveryFeeSat: UInt64 = 500
    static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }

    init(keys: any StoreKeyVault) { self.keys = keys }

    func prepare(directory root: URL, headers: HeaderChain) async throws {
        if engine == nil {
            let dir = root.appending(path: "lightning", directoryHint: .isDirectory)
            let existing = try keys.key(for: "lightning-journal-v2")
            let hasJournal = FileManager.default.fileExists(atPath: dir.appending(path: "journal.v1").path)
            guard (existing != nil) == hasJournal else { throw LightningError.storageFailed }
            let key = try existing ?? keys.establishKey(for: "lightning-journal-v2")
            let journal = try FileLightningJournal(directory: dir, key: key.withUnsafeBytes { Data($0) })
            #if DEBUG
            let nodeSecret = fixtureNodeSecret
            #else
            let nodeSecret: Data? = nil
            #endif
            let opened = try LightningEngine(chain: NetworkParams.params(for: .regtest).genesisHash, nodeSecret: nodeSecret, journal: journal)
            try await opened.persistIdentity()
            directory = dir
            let loaded = try loadProfile()
            engine = opened; profile = loaded
        }
        guard let engine else { throw LightningError.storageFailed }
        driver = LightningChainDriver(engine: engine, headers: headers)
        try await refresh()
    }
    private func loadProfile() throws -> LightningProfile? {
        guard let file = directory?.appending(path: "profile.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-profile", keys: keys).read(Data(contentsOf: file), network: .regtest)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        return try LightningProfile.parse(String(decoding: sealed.payload, as: UTF8.self))
    }
    func saveProfile(_ proposed: LightningProfile, model: AppModel) async throws {
        try proposed.validate()
        guard let directory, let engine else { throw AppModel.AppError.noStack }
        if let current = profile, current.peerKey != proposed.peerKey {
            guard await engine.channels().isEmpty else { throw LightningError.invalidState }
        }
        let epoch = generation
        try await model.authenticateSensitiveAction(reason: "Approve this regtest Lightning provider and recovery policy")
        defer { model.keychainAuthentication.revoke() }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        try StoreSeal(store: "lightning-profile", keys: keys).write(JSONEncoder().encode(proposed), network: .regtest,
            to: directory.appending(path: "profile.json")) { data, file in
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
        // Receiving-path or fee updates do not change the authenticated TCP
        // peer. Keep that session while the new profile becomes durable.
        let sameEndpoint = profile?.peer == proposed.peer && profile?.host == proposed.host && profile?.port == proposed.port
        if !sameEndpoint { await stop() }
        profile = proposed
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
            try await refresh()
            model.e2e?.journal("lightning.resume", fields: ["connection": connection, "connecting": String(connecting), "chainCurrent": String(chainCurrent)])
            guard chainCurrent, let engine, let profile, !connecting else { return }
            if await session?.status == .connected {
                try await resumeSubmittedFunding(model: model)
                try await session?.flush()
                return
            }
            connecting = true; defer { connecting = false }
            let epoch = generation
            let next = LightningPeerSession(engine: engine, peer: profile.peerKey, host: profile.host, port: profile.port) { [weak self, weak model] events in
                guard let self, let model else { throw CancellationError() }
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
        balances = try await engine.channelBalances(); funding = try await engine.fundingRequests()
        offers = try await engine.receiveOffers(now: Self.now)
        chainCurrent = await engine.isChainCurrent()
        switch await session?.status {
        case .connected: connection = chainCurrent ? "Connected" : "Verifying chain"
        case .connecting: connection = "Connecting"
        case .failed(let reason): connection = "Disconnected: \(reason)"
        default: connection = chainCurrent ? "Ready to connect" : "Waiting for verified chain"
        }
    }
    func handle(_ events: [LightningEngine.Event], model: AppModel) async throws {
        guard let stack = model.stack, let wallet = model.wallet else { throw AppModel.AppError.noStack }
        for event in events {
            switch event {
            case .broadcastFunding(_, let raw):
                guard let reservation = await wallet.fundingReservations.first(where: { $0.rawTransaction == raw }) else {
                    throw LightningError.storageFailed
                }
                _ = try await stack.broadcaster.broadcast(raw, feeRateSatPerVByte: reservation.feeRateSatPerVByte)
                try await wallet.commitFundingBroadcast(requestID: reservation.requestID, rawTransaction: raw)
            case .broadcastClose(_, let raw), .broadcastRecovery(_, let raw):
                _ = try await stack.broadcaster.broadcast(raw)
            case .channelReady: try await configureRecovery(model: model)
            case .fundingRequired, .paymentChanged: break
            }
        }
        try await refresh()
    }
    private func configureRecovery(model: AppModel) async throws {
        guard profile != nil, let engine, let wallet = model.wallet else { return }
        let balances = try await engine.channelBalances()
        for channel in await engine.channels() where balances.contains(where: { $0.id == channel.id && !$0.recoveryConfigured }) {
            let address = try await wallet.freshReceiveAddress()
            let destination = try AddressDecoder.scriptPubKey(for: address, network: .regtest)
            try await engine.configureRecovery(channelID: channel.id, peer: channel.peer, destination: destination, feeSat: Self.recoveryFeeSat)
        }
    }
}
