import Foundation

extension LightningEngine {
    public struct OfferPayment: Codable, Sendable, Equatable {
        public let id: Data, channelID: Data, offer: Data
        public let amountMsat: UInt64, feeLimitMsat: UInt64
        public let maximumDelta: UInt32
        public let route: AsyncPaymentRoute
        public init(id: Data, channelID: Data, offer: LightningOffer, amountMsat: UInt64,
                    feeLimitMsat: UInt64, maximumDelta: UInt32 = 2016, route: AsyncPaymentRoute) {
            self.id = id; self.channelID = channelID; self.offer = offer.bytes; self.amountMsat = amountMsat
            self.feeLimitMsat = feeLimitMsat; self.maximumDelta = maximumDelta; self.route = route
        }
    }
    struct AsyncOutgoing: Codable {
        let request: OfferPayment
        let invoiceRequest: Data, preimage: Data
        let requestedAt: UInt64
        var invoice: Data?
        var releasePath: BlindedPath?
        var notified = false
    }
    struct AsyncState: Codable {
        var outgoing: [AsyncOutgoing] = []
        var receives: [AsyncReceive] = []
        var outbox: [OnionOutbound] = []
    }
    public struct OnionOutbound: Codable, Sendable, Equatable {
        public let sequence: UInt64
        public let peer: Data, message: LightningWire.Message
        let key: Data
        let expiresAt: UInt64
    }
    var asyncAuthKey: Data { OnionPacket.derive("winnow_async_context_v1", secret: state.nodeSecret) }
    func replyPath(purpose: UInt8, id: Data, through peers: [Data]) throws -> BlindedPath {
        try OnionMessage.path(nodes: peers + [nodeID()], context: Data([purpose]) + id, authenticationKey: asyncAuthKey)
    }
    /// Messages remain durable until the transport confirms publication or an
    /// authenticated reply supersedes them. A disconnect before acknowledgement
    /// replays the exact bytes; application operations are idempotent.
    public func pendingOnionMessages(peer: Data, now: UInt64) throws -> [OnionOutbound] {
        try operational(peer)
        return state.async.outbox.filter { $0.peer == peer && $0.expiresAt >= now }
    }
    public func onionMessagePublished(sequence: UInt64) throws {
        try healthy()
        guard state.async.outbox.contains(where: { $0.sequence == sequence }) else { return }
        var next = state
        next.async.outbox.removeAll { $0.sequence == sequence }
        try persist(next)
    }
    func enqueueOnion(to originalPath: BlindedPath, through: [Data], content: LightningWire.TLV,
                      reply: BlindedPath?, key: Data, expiresAt: UInt64, in next: inout State) throws {
        guard next.async.outbox.count < 1024, next.nextSequence < .max else { throw LightningError.invalidState }
        let path: BlindedPath
        if case .channel(_, let scid) = originalPath.introduction {
            guard let route = next.async.outgoing.first(where: { $0.request.route.shortChannelID == scid })?.request.route else { throw LightningError.invalidMessage }
            path = try route.resolve(originalPath)
        } else { path = originalPath }
        let first: Data
        if let peer = through.first { first = peer }
        else if case .node(let node) = path.introduction { first = node }
        else { throw LightningError.invalidMessage }
        let prefix: [Data]
        if case .node(let intro) = path.introduction, through.last == intro { prefix = Array(through.dropLast()) }
        else { prefix = through }
        let message = try OnionMessage.create(to: path, via: prefix, content: content, reply: reply)
        next.async.outbox.removeAll { $0.key == key }
        next.async.outbox.append(OnionOutbound(sequence: next.nextSequence, peer: first, message: message, key: key, expiresAt: expiresAt))
        next.nextSequence += 1
    }
    public func receiveOnionMessage(_ message: LightningWire.Message, now: UInt64) throws -> [Event] {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        guard message.type == 513 else { throw LightningError.invalidMessage }
        do { return try dispatchOnion(message, now: now) }
        catch {
            // BOLT4 onion messages are best effort and independent of channel
            // state. Invalid, obsolete or unsolicited payloads must not stop
            // commitment/revocation processing. An uncertain write still stops
            // the entire engine and must propagate to the transport owner.
            try healthy()
            return []
        }
    }
    private func dispatchOnion(_ message: LightningWire.Message, now: UInt64) throws -> [Event] {
        guard case .receive(let content, let context, let reply) = try OnionMessage.peel(message, nodeSecret: state.nodeSecret, authenticationKey: asyncAuthKey),
              context.count == 33 else { throw LightningError.invalidMessage }
        let id = Data(context.dropFirst())
        switch context.first {
        case 1: return try acceptStaticInvoice(content, id: id, now: now)
        case 2: try receiveOfferRegistration(content, reply: reply, id: id, now: now)
        case 3: try releaseHeldPayment(content, reply: reply, id: id, now: now)
        case 4: try replyToInvoiceRequest(content, reply: reply, id: id, now: now)
        default: throw LightningError.invalidMessage
        }
        return []
    }
}
