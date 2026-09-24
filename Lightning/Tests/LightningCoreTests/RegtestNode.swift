#if os(macOS)
import Foundation
import Darwin
import TestSupport
import WalletCore

/// Disposable Bitcoin Core process. RPC is confined to test setup, mining,
/// and assertions. Wallet/Lightning chain data and relay use Winnow's P2P stack.
final class RegtestNode: @unchecked Sendable {
    enum Failure: Error { case unavailable, command(String), port }
    let directory: URL
    let binaryDirectory: String
    let p2pPort: UInt16
    let rpcPort: UInt16
    private var stopped = false

    init() throws {
        guard let path = ProcessInfo.processInfo.environment["WINNOW_BITCOIN_DIR"] else { throw Failure.unavailable }
        binaryDirectory = path
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-regtest-\(UUID().uuidString)")
        p2pPort = try Self.unusedPort()
        var rpc = try Self.unusedPort()
        while rpc == p2pPort { rpc = try Self.unusedPort() }
        rpcPort = rpc
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try HostProcess.run(path + "/bitcoind", [
            "-regtest", "-datadir=\(directory.path)", "-server", "-daemonwait", "-listen=1",
            "-rpcport=\(rpcPort)", "-port=\(p2pPort)", "-bind=127.0.0.1:\(p2pPort)",
            "-listenonion=0", "-dnsseed=0", "-fixedseeds=0", "-connect=0", "-discover=0",
            "-blockfilterindex=1", "-peerblockfilters=1", "-fallbackfee=0.00002",
        ])
        guard result.status == 0 else {
            let diagnostic = (try? String(contentsOf: directory.appendingPathComponent("regtest/debug.log"), encoding: .utf8)) ?? ""
            stopped = true
            try? FileManager.default.removeItem(at: directory)
            throw Failure.command("bitcoind exited \(result.status): " + result.stderr + result.stdout + String(diagnostic.suffix(4000)))
        }
    }

    deinit { stop() }

    @discardableResult
    func rpc(_ args: [String], wallet: String? = nil) throws -> String {
        var flags = ["-regtest", "-datadir=\(directory.path)", "-rpcconnect=127.0.0.1", "-rpcport=\(rpcPort)"]
        if let wallet { flags.append("-rpcwallet=\(wallet)") }
        let result = try HostProcess.run(binaryDirectory + "/bitcoin-cli", flags + args)
        guard result.status == 0 else { throw Failure.command("bitcoin-cli \(args.first ?? "") exited \(result.status): " + result.stderr + result.stdout) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func waitForFilters() async throws {
        let height = try rpc(["getblockcount"])
        for _ in 0..<250 {
            let result = try rpc(["getindexinfo"])
            if let indexes = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: [String: Any]],
               indexes.values.contains(where: { ($0["synced"] as? Bool) == true && ($0["best_block_height"] as? Int) == Int(height) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.command("Compact-filter index did not catch up")
    }

    func stop() {
        guard !stopped else { return }
        _ = try? rpc(["stop"])
        stopped = true
        // A stop RPC acknowledges before database shutdown. Removing the
        // directory then races Core's final writes and leaks daemon processes.
        let pid = directory.appendingPathComponent("regtest/bitcoind.pid")
        for _ in 0..<250 where FileManager.default.fileExists(atPath: pid.path) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !FileManager.default.fileExists(atPath: pid.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.port }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw Failure.port }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard found == 0 else { throw Failure.port }
        return UInt16(bigEndian: address.sin_port)
    }
}
#endif
