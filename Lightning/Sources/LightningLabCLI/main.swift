import Foundation
import Security
import LightningCore
import LightningLab
import WalletCore

/// User-operated regtest peer. No Bitcoin RPC client is linked into its actions.
@main
enum LightningLabCLI {
    struct Configuration: Decodable {
        let bitcoin_host: String
        let bitcoin_port: UInt16
        let listen_port: UInt16
        let advertised_host: String
        let provider: Bool
    }
    struct Command: Decodable {
        let command: String
        var card_file: String?
        var host: String?
        var port: UInt16?
        var node_id: String?
        var amount_sat: UInt64?
        var request_id: String?
        var claim_id: String?
        var file: String?
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("usage: winnow-lightning-lab CONFIG.json STATE-DIRECTORY\nCommands are newline-delimited JSON on stdin; see Lightning/LAB.md.")
            return
        }
        let configuration = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let seedPath = root.appending(path: "regtest-seed")
        let seed: Data
        if FileManager.default.fileExists(atPath: seedPath.path) { seed = try Data(contentsOf: seedPath) }
        else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LightningError.invalidSeed }
            seed = Data(bytes)
            try seed.write(to: seedPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seedPath.path)
        }
        let node = try LightningLabNode(directory: root, seed: seed,
            bitcoinPeer: PeerEndpoint(host: configuration.bitcoin_host, port: configuration.bitcoin_port),
            listenPort: configuration.listen_port,
            provider: configuration.provider ? LightningClaimProvider(host: configuration.advertised_host,
                port: configuration.listen_port) : nil, forwarding: true)
        let port = try await node.start()
        let card = try await node.peerCard()
        try Data(card.utf8).write(to: root.appending(path: "public-peer-card.json"), options: .atomic)
        let address = try await node.wallet.freshReceiveAddress()
        print("REGTEST ONLY: listening on \(port); fund Winnow address \(address). Public card: \(root.appending(path: "public-peer-card.json").path)")
        while let line = await Task.detached(operation: { readLine() }).value {
            do {
                let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
                func required<T>(_ value: T?) throws -> T {
                    guard let value else { throw LightningError.invalidResponse }; return value
                }
                switch command.command {
                case "stop": await node.stop(); return
                case "pin":
                    try await node.pin(card: String(contentsOfFile: required(command.card_file), encoding: .utf8))
                case "connect":
                    try await node.connect(card: String(contentsOfFile: required(command.card_file), encoding: .utf8),
                        host: required(command.host), port: required(command.port))
                case "open":
                    try await node.openChannel(to: required(command.node_id), amountSat: required(command.amount_sat))
                case "prepare":
                    let amount = try required(command.amount_sat)
                    guard (5000...100000).contains(amount) else { throw LightningError.invalidResponse }
                    try await node.consume(node.engine.prepareClaim(requestID: required(command.request_id),
                        provider: required(command.node_id), host: required(command.host), port: required(command.port),
                        amountMsat: amount * 1000))
                case "commit", "cancel":
                    let id = try required(command.claim_id)
                    let claim = try required(try await node.status().claims[id])
                    if command.command == "commit" { try await node.consume(node.engine.commitClaim(claim)) }
                    else { try await node.consume(node.engine.cancelClaim(id: id)) }
                case "export":
                    let token = try await node.engine.exportClaim(id: required(command.claim_id))
                    let file = URL(fileURLWithPath: try required(command.file))
                    guard !FileManager.default.fileExists(atPath: file.path) else { throw LightningError.invalidResponse }
                    try Data(token.utf8).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    print("Saved bearer claim to requested file; keep it private.")
                case "import":
                    let file = URL(fileURLWithPath: try required(command.file))
                    guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 32768 else { throw LightningError.invalidResponse }
                    try await node.consume(node.engine.importClaim(String(contentsOf: file, encoding: .utf8)))
                case "redeem": try await node.consume(node.engine.redeemClaim(id: required(command.claim_id)))
                case "status": break
                default: throw LightningError.invalidResponse
                }
                let status = try await node.status()
                let balance = await node.wallet.balance
                let summary: [String: Any] = ["node_id": status.node_id, "height": status.height,
                    "chain_ready": status.chain_ready, "wallet_sats": balance, "peers": status.peers,
                    "channels": status.channels.map { ["node_id": $0.node_id, "usable": $0.usable,
                        "available_msat": $0.outbound_capacity_msat] as [String: Any] },
                    "claims": status.claims.values.map { ["id": $0.claim_id, "state": $0.state,
                        "amount_msat": $0.amount_msat] as [String: Any] }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
            } catch { print("Command failed: \(error.localizedDescription)") }
        }
        await node.stop()
    }
}
