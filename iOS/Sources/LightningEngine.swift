import Foundation
import LDKNode
import Security

struct PeerConfiguration {
    var nodeID: String
    var address: String
    var kemHex: String
    var signingHex: String

    var isComplete: Bool {
        !nodeID.isEmpty && !address.isEmpty && !kemHex.isEmpty && !signingHex.isEmpty
    }
}

struct PeerPin: Codable {
    var nodeID: String
    var kemHex: String
}

struct LightningSnapshot {
    var nodeID: String
    var signingKey: String
    var kemKey: String
    var address: String
    var onchainSats: UInt64
    var lightningSats: UInt64
    var channels: [ChannelSummary]
    var events: [String]
}

struct ChannelSummary: Identifiable {
    var id: String
    var peer: String
    var amountSats: UInt64
    var outboundSats: UInt64
    var inboundSats: UInt64
    var ready: Bool
}

enum LightningSetupError: LocalizedError {
    case missingServer
    case badHex(String, Int)
    case keychain(OSStatus)
    case random(OSStatus)
    case nodeStopped
    case pinChanged

    var errorDescription: String? {
        switch self {
        case .missingServer: return "Enter your regtest Esplora URL first."
        case let .badHex(name, bytes): return "\(name) needs exactly \(bytes * 2) hexadecimal characters."
        case let .keychain(status): return "Could not open the local seed in Keychain (\(status))."
        case let .random(status): return "Could not create a local seed (\(status))."
        case .nodeStopped: return "Start the node first."
        case .pinChanged: return "This peer's ML-KEM key differs from the saved pin. Check its identity before trying a different key."
        }
    }
}

private enum Hex {
    static func decode(_ value: String, bytes: Int, name: String) throws -> Data {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == bytes * 2, text.utf8.allSatisfy({ $0 < 128 &&
            ($0 >= 48 && $0 <= 57 || $0 >= 65 && $0 <= 70 || $0 >= 97 && $0 <= 102) }) else {
            throw LightningSetupError.badHex(name, bytes)
        }
        var result = Data(capacity: bytes)
        var index = text.startIndex
        for _ in 0..<bytes {
            let next = text.index(index, offsetBy: 2)
            result.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    static func encode(_ value: Data?) -> String {
        value?.map { String(format: "%02x", $0) }.joined() ?? ""
    }
}

private enum SeedStore {
    static let account = "regtest-node-seed-v1"

    static func loadOrCreate() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.btcswift.lightning",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let seed = item as? Data, seed.count == 64 { return seed }
        guard status == errSecItemNotFound else { throw LightningSetupError.keychain(status) }
        var seed = Data(count: 64)
        let randomStatus = seed.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 64, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw LightningSetupError.random(randomStatus) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.btcswift.lightning",
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: seed
        ]
        let saveStatus = SecItemAdd(add as CFDictionary, nil)
        if saveStatus == errSecDuplicateItem { return try loadOrCreate() }
        guard saveStatus == errSecSuccess else { throw LightningSetupError.keychain(saveStatus) }
        return seed
    }
}

final class LightningEngine {
    private let queue = DispatchQueue(label: "com.btcswift.lightning.engine")
    private var node: Node?
    private var cachedAddress = ""
    private var recentEvents: [String] = []

    func start(server: String, listenAddress: String, announceAddress: String,
               peer: PeerConfiguration, savedPins: [PeerPin],
               completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                let url = server.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                    throw LightningSetupError.missingServer
                }
                if let existing = self.node { try? existing.stop(); self.node = nil }
                let seed = try SeedStore.loadOrCreate()
                let entropy = try NodeEntropy.fromSeedBytes(seedBytes: seed)
                let builder = Builder()
                builder.setNetwork(network: .regtest)
                builder.setChainSourceEsplora(serverUrl: url, syncConfig: nil)
                builder.setGossipSourceP2p()
                let listen = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let announce = announceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                if !listen.isEmpty { try builder.setListeningAddresses(listeningAddresses: [listen]) }
                if !announce.isEmpty { try builder.setAnnouncementAddresses(announcementAddresses: [announce]) }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let storage = support.appendingPathComponent("PQLN-regtest", isDirectory: true)
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                builder.setStorageDirPath(storageDirPath: storage.path)
                let node = try builder.build(nodeEntropy: entropy)
                for pin in savedPins {
                    let kem = try Hex.decode(pin.kemHex, bytes: 1184, name: "Saved peer ML-KEM key")
                    try node.registerPqPeerBytes(nodeId: pin.nodeID, kemKey: kem)
                }
                if !peer.nodeID.isEmpty && !peer.kemHex.isEmpty {
                    if let existing = savedPins.first(where: { $0.nodeID == peer.nodeID }),
                       existing.kemHex.lowercased() != peer.kemHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                        throw LightningSetupError.pinChanged
                    }
                    let kem = try Hex.decode(peer.kemHex, bytes: 1184, name: "Peer ML-KEM key")
                    try node.registerPqPeerBytes(nodeId: peer.nodeID, kemKey: kem)
                }
                try node.start()
                self.node = node
                self.cachedAddress = try node.onchainPayment().newAddress()
                self.recentEvents.insert("Regtest node started", at: 0)
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    func stop(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                if let node = self.node { try node.stop() }
                self.node = nil
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    func refresh(completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                while let event = node.nextEvent() {
                    self.recentEvents.insert(self.label(event), at: 0)
                    self.recentEvents = Array(self.recentEvents.prefix(12))
                    try node.eventHandled()
                }
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    func sync(completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                try node.syncWallets()
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    func connect(peer: PeerConfiguration, savedPins: [PeerPin], completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                if let existing = savedPins.first(where: { $0.nodeID == peer.nodeID }),
                   existing.kemHex.lowercased() != peer.kemHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    throw LightningSetupError.pinChanged
                }
                let kem = try Hex.decode(peer.kemHex, bytes: 1184, name: "Peer ML-KEM key")
                try node.registerPqPeerBytes(nodeId: peer.nodeID, kemKey: kem)
                var pins = savedPins.filter { $0.nodeID != peer.nodeID }
                pins.append(PeerPin(nodeID: peer.nodeID,
                                    kemHex: peer.kemHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
                UserDefaults.standard.set(try JSONEncoder().encode(pins), forKey: "pinnedPeers")
                UserDefaults.standard.synchronize()
                try node.connect(nodeId: peer.nodeID, address: peer.address, persist: true)
                self.recentEvents.insert("PQLN peer connected", at: 0)
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    func openChannel(peer: PeerConfiguration, sats: UInt64, announced: Bool,
                     completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                if announced {
                    _ = try node.openAnnouncedChannel(nodeId: peer.nodeID, address: peer.address,
                        channelAmountSats: sats, pushToCounterpartyMsat: nil, channelConfig: nil)
                } else {
                    _ = try node.openChannel(nodeId: peer.nodeID, address: peer.address,
                        channelAmountSats: sats, pushToCounterpartyMsat: nil, channelConfig: nil)
                }
                self.recentEvents.insert("Channel opening requested: \(sats) sats", at: 0)
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    func invoice(msat: UInt64, memo: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                let invoice = try node.bolt11Payment().receive(amountMsat: msat, description: .direct(description: memo), expirySecs: 3600)
                completion(.success(invoice.description))
            } catch { completion(.failure(error)) }
        }
    }

    func pay(invoice text: String, trustedSigningHex: String, completion: @escaping (Result<LightningSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let node = self.node else { throw LightningSetupError.nodeStopped }
                let key = try Hex.decode(trustedSigningHex, bytes: 1312, name: "Trusted ML-DSA key")
                try node.verifyPqInvoice(invoiceText: text, trustedKey: key)
                let invoice = try Bolt11Invoice.fromStr(invoiceStr: text.trimmingCharacters(in: .whitespacesAndNewlines))
                _ = try node.bolt11Payment().send(invoice: invoice, routeParameters: nil)
                self.recentEvents.insert("Verified PQLN payment started", at: 0)
                completion(.success(self.snapshot(node)))
            } catch { completion(.failure(error)) }
        }
    }

    private func snapshot(_ node: Node) -> LightningSnapshot {
        let balance = node.listBalances()
        return LightningSnapshot(
            nodeID: node.nodeId(),
            signingKey: Hex.encode(node.pqNodeIdBytes()),
            kemKey: Hex.encode(node.pqKemNodeIdBytes()),
            address: cachedAddress,
            onchainSats: balance.spendableOnchainBalanceSats,
            lightningSats: balance.totalLightningBalanceSats,
            channels: node.listChannels().map { channel in
                ChannelSummary(id: channel.channelId, peer: channel.counterparty.nodeId,
                    amountSats: channel.channelValueSats,
                    outboundSats: channel.outboundCapacityMsat / 1000,
                    inboundSats: channel.inboundCapacityMsat / 1000,
                    ready: channel.isChannelReady)
            },
            events: recentEvents
        )
    }

    private func label(_ event: Event) -> String {
        switch event {
        case .paymentSuccessful: return "Payment succeeded"
        case .paymentFailed: return "Payment failed"
        case .paymentReceived: return "Payment received"
        case .channelPending: return "Channel pending"
        case .channelReady: return "Channel ready"
        case .channelClosed: return "Channel closed"
        default: return "Lightning event"
        }
    }
}
