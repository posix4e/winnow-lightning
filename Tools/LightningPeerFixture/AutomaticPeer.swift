import Foundation
import LightningCore

/// An independently running receive loop for the process-lifecycle fixtures.
/// Channel/async decisions and all durable state remain in LightningEngine.
actor AutomaticPeer {
    let engine: LightningEngine, connection: LightningConnection, peer: Data
    var sent = Set<UInt64>(), sending = false
    var events: [[String: String]] = []
    init(engine: LightningEngine, connection: LightningConnection, peer: Data) {
        self.engine = engine; self.connection = connection; self.peer = peer
    }
    func run() async {
        do {
            try await flush()
            while !Task.isCancelled {
                let event = try await PeerFixture.receive(engine: engine, connection: connection, peer: peer)
                events.append(event)
                try await flush()
            }
        } catch {
            FileHandle.standardError.write(Data("Automatic peer stopped: \(error)\n".utf8))
            events.append(["error": String(describing: error)])
            await connection.close(); await engine.peerDisconnected(peer)
        }
    }
    func flush() async throws {
        guard !sending else { return }
        sending = true; defer { sending = false }
        for item in try await engine.pendingMessages(peer: peer) where !sent.contains(item.sequence) {
            try await connection.send(item.message); sent.insert(item.sequence)
        }
        for item in try await engine.pendingOnionMessages(peer: peer, now: UInt64(Date().timeIntervalSince1970)) {
            try await connection.send(item.message)
            try await engine.onionMessagePublished(sequence: item.sequence)
        }
    }
    func drain() throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        events.removeAll(); return String(decoding: encoded, as: UTF8.self)
    }
}

extension PeerFixture {
    static func asyncCommand(_ input: [String: String], engine: LightningEngine, peer: Data) async throws -> [String: String] {
        let now = UInt64(Date().timeIntervalSince1970)
        switch input["command"] {
        case "height":
            guard let height = UInt32(input["height"] ?? "") else { throw LightningError.invalidMessage }
            try await engine.chainCaughtUp(height: height); return ["height": String(height)]
        case "async_pay":
            guard let id = Data(hex: input["id"] ?? ""), let channel = Data(hex: input["channel"] ?? ""), let intro = Data(hex: input["introduction"] ?? ""),
                  let scid = UInt64(input["scid"] ?? ""), let amount = UInt64(input["amount"] ?? ""), let fee = UInt64(input["fee"] ?? "") else { throw LightningError.invalidMessage }
            let route = try AsyncPaymentRoute(holdingPeer: peer, introduction: intro, shortChannelID: scid, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48)
            let request = try LightningEngine.OfferPayment(id: id, channelID: channel, offer: LightningOffer(string: input["offer"] ?? ""),
                amountMsat: amount, feeLimitMsat: fee, maximumDelta: 2016, route: route)
            let payment = try await engine.payOffer(request, now: now)
            return ["id": payment.id.hex, "hash": payment.hash.hex, "phase": payment.phase.rawValue]
        case "async_register":
            guard let id = Data(hex: input["id"] ?? ""), let path = Data(hex: input["path"] ?? ""), let scid = UInt64(input["scid"] ?? ""),
                  let server = try BlindedPath.decodeList(path).first else { throw LightningError.invalidMessage }
            try await engine.registerReceiveOffer(.init(id: id, provider: peer, serverPath: server, inboundShortChannelID: scid,
                baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48, maximumMsat: 50_000_000), now: now)
            return ["phase": "registering"]
        case "async_offer":
            guard let receive = try await engine.receiveOffers(now: now).first else { return ["phase": "registering"] }
            return ["phase": "ready", "offer": receive.offer.string, "id": receive.id.hex]
        default: throw LightningError.invalidMessage
        }
    }
}
