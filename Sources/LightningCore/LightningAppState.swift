import Foundation

extension LightningEngine {
    public func isChainCurrent() -> Bool { chainIsCurrent }
    public struct FundingRequest: Sendable, Equatable {
        public let temporaryID: Data, peer: Data, scriptPubKey: Data
        public let amountSat: UInt64
    }
    /// Derived from durable accepted channels, so an interrupted app callback
    /// never loses the funding review. It is not authorization to fund.
    public func fundingRequests() throws -> [FundingRequest] {
        try healthy()
        return try state.channels.filter { $0.isFunder && $0.phase == .accepted }.map {
            try FundingRequest(temporaryID: $0.temporaryID, peer: $0.peer, scriptPubKey: $0.fundingScript(), amountSat: $0.capacity)
        }
    }
    /// Save a fresh identity before displaying its public key to a provider.
    public func persistIdentity() throws {
        try healthy()
        if state.revision == 0 { try persist(state) }
    }
    public struct ChannelBalance: Sendable {
        public let id: Data
        public let localMsat: UInt64, remoteMsat: UInt64
        public let recoveryConfigured: Bool
    }
    public func channelBalances() throws -> [ChannelBalance] {
        try healthy()
        return try state.channels.map { channel in
            let view = try channel.view(localOwner: true, number: channel.localNumber)
            return ChannelBalance(id: channel.id, localMsat: view.localMsat, remoteMsat: view.remoteMsat,
                                  recoveryConfigured: channel.recovery != nil)
        }
    }
}
