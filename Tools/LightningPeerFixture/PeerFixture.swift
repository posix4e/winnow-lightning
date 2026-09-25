import Foundation
import LightningCore
import WalletCore

/// Host-only RPC adapter. All Lightning cryptography, wire/state transitions,
/// transaction construction and persistence use the production Swift module.
/// Python supplies disposable regtest coins and assertions, not peer signatures.
@main
struct PeerFixture {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Swift peer fixture: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, let port = UInt16(args[1]), let peer = Data(hex: args[2]), let chain = Data(hex: args[3])
        else { throw LightningError.invalidMessage }
        let secret = Data(repeating: 1, count: 32)
        let connection = try LightningConnection(host: args[0], port: port, secret: secret, peer: peer)
        let journal = try FileLightningJournal(directory: URL(fileURLWithPath: args[4]), key: Data(repeating: 42, count: 32))
        let engine = try LightningEngine(chain: chain, nodeSecret: secret, journal: journal)
        try await engine.chainCaughtUp() // The test driver has synchronized its own regtest fixture.
        try await connection.start()
        try await connection.send(LightningFeatures.channelOpening.initialization())
        let initialization = try await connection.receive()
        let features = try LightningFeatures.readInitialization(initialization)
        FileHandle.standardError.write(Data("Reference init features: \(features.bits.sorted())\n".utf8))
        try await engine.peerInitialized(peer, features: features)
        try emit(["status": "initialized", "node_id": try ChannelKeys.publicKey(secret: secret).hex,
                  "peer_features": features.bytes.hex])
        var sent = Set<UInt64>()
        while let line = readLine() {
            let input = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
            let output = try await execute(input, engine: engine, connection: connection, peer: peer)
            for pending in try await engine.pendingMessages(peer: peer) where !sent.contains(pending.sequence) {
                try await connection.send(pending.message); sent.insert(pending.sequence)
            }
            try emit(output)
        }
        await connection.close()
    }
    static func execute(_ input: [String: String], engine: LightningEngine,
                        connection: LightningConnection, peer: Data) async throws -> [String: String] {
        switch input["command"] {
        case "open":
            let id = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
            return ["temporary_id": id.hex]
        case "receive": return try await receive(engine: engine, connection: connection, peer: peer)
        case "fund":
            guard let id = Data(hex: input["id"] ?? ""), let raw = Data(hex: input["transaction"] ?? ""),
                  let output = UInt16(input["output"] ?? "") else { throw LightningError.invalidMessage }
            try await engine.provideFunding(temporaryID: id, peer: peer, transaction: Transaction.decode(raw), output: output)
            return ["status": "funding_created"]
        case "confirm":
            guard let id = Data(hex: input["id"] ?? ""), let raw = Data(hex: input["transaction"] ?? "") else { throw LightningError.invalidMessage }
            let events = try await engine.fundingConfirmed(channelID: id, peer: peer, transaction: Transaction.decode(raw), confirmations: 6)
            return encode(events)
        case "snapshot":
            guard let channel = await engine.channels().first else { throw LightningError.invalidState }
            return ["id": channel.id.hex, "phase": channel.phase.rawValue, "commitment": channel.signedCommitment?.hex ?? ""]
        case "peel":
            guard let onion = Data(hex: input["onion"] ?? ""), let hash = Data(hex: input["hash"] ?? "") else { throw LightningError.invalidMessage }
            let peeled = try OnionPacket.peel(onion, secret: Data(repeating: 1, count: 32), associatedData: hash)
            return ["payload": peeled.payload.hex, "shared_secret": peeled.sharedSecret.hex, "next": peeled.next?.hex ?? ""]
        case "pay":
            guard let id = Data(hex: input["id"] ?? ""), let channel = Data(hex: input["channel"] ?? ""),
                  let hash = Data(hex: input["hash"] ?? ""), let secret = Data(hex: input["secret"] ?? ""),
                  let amount = UInt64(input["amount"] ?? ""), let expiry = UInt32(input["expiry"] ?? "") else { throw LightningError.invalidMessage }
            let payment = try await engine.payDirect(.init(id: id, peer: peer, channelID: channel, paymentHash: hash,
                paymentSecret: secret, amountMsat: amount, feeLimitMsat: 0, expiry: expiry))
            return ["id": payment.id.hex, "phase": payment.phase.rawValue]
        case "invoice":
            guard let id = Data(hex: input["id"] ?? ""), let amount = UInt64(input["amount"] ?? ""),
                  let expiry = UInt32(input["expiry"] ?? "") else { throw LightningError.invalidMessage }
            let invoice = try await engine.registerReceive(id: id, amountMsat: amount, expiry: expiry)
            return ["id": invoice.id.hex, "hash": invoice.paymentHash.hex, "secret": invoice.paymentSecret.hex]
        case "payment":
            guard let id = Data(hex: input["id"] ?? ""), let payment = await engine.payments().first(where: { $0.id == id }) else {
                return ["phase": "missing"]
            }
            return ["phase": payment.phase.rawValue, "hash": payment.hash.hex, "preimage": payment.preimage?.hex ?? ""]
        case "close":
            guard let id = Data(hex: input["id"] ?? ""), let destination = Data(hex: input["destination"] ?? "") else { throw LightningError.invalidMessage }
            try await engine.closeChannel(channelID: id, peer: peer, destination: destination, feeSat: 500, maximumFeeSat: 724)
            return ["phase": "closing"]
        case "recovery":
            guard let id = Data(hex: input["id"] ?? ""), let destination = Data(hex: input["destination"] ?? "") else { throw LightningError.invalidMessage }
            try await engine.configureRecovery(channelID: id, peer: peer, destination: destination, feeSat: 500)
            return ["status": "recovery_configured"]
        case "force_close":
            guard let id = Data(hex: input["id"] ?? "") else { throw LightningError.invalidMessage }
            return encode([try await engine.forceClose(channelID: id, peer: peer)])
        default: throw LightningError.invalidMessage
        }
    }
    static func receive(engine: LightningEngine, connection: LightningConnection, peer: Data) async throws -> [String: String] {
        let message = try await connection.receive()
        if message.type == 18 {
            var reader = LightningWire.Reader(message.payload)
            let count = try reader.u16(), ignored = try reader.u16(); _ = try reader.take(Int(ignored)); try reader.requireEnd()
            if count < 65_532 {
                var writer = LightningWire.Writer(); writer.u16(count); writer.append(Data(repeating: 0, count: Int(count)))
                try await connection.send(.init(type: 19, payload: writer.data))
            }
            return ["type": "18"]
        }
        guard (32...39).contains(message.type) || (128...136).contains(message.type) else { return ["type": String(message.type), "payload": message.payload.hex] }
        var output = encode(try await engine.receive(peer: peer, message: message))
        output["type"] = String(message.type)
        return output
    }
    static func encode(_ events: [LightningEngine.Event]) -> [String: String] {
        guard let event = events.first else { return [:] }
        switch event {
        case .fundingRequired(let id, let amount, let script):
            return ["event": "funding_required", "id": id.hex, "amount_sat": String(amount), "script": script.hex]
        case .broadcastFunding(let id, let transaction):
            return ["event": "broadcast_funding", "id": id.hex, "transaction": transaction.hex]
        case .channelReady(let id): return ["event": "channel_ready", "id": id.hex]
        case .paymentChanged(let payment): return ["event": "payment_changed", "id": payment.id.hex, "phase": payment.phase.rawValue]
        case .broadcastClose(let id, let transaction): return ["event": "broadcast_close", "id": id.hex, "transaction": transaction.hex]
        case .broadcastRecovery(let id, let transaction): return ["event": "broadcast_recovery", "id": id.hex, "transaction": transaction.hex]
        }
    }
    static func emit(_ value: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
