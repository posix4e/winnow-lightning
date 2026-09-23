import WalletCore
import ChainWatchCore
import Darwin
import Foundation

private enum UsageError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self { case let .message(text): text }
    }
}

private struct Options {
    let network: NetworkParams
    let stateDirectory: URL
    let startHeight: UInt32
    let watch: ChannelWatch
    let peers: [PeerEndpoint]
    let follow: Bool

    init(arguments: [String]) throws {
        var statePath: String?
        var network: NetworkParams = .regtest
        var startHeight: UInt32 = 0
        var scriptHex: String?
        var outpointText: String?
        var peers: [PeerEndpoint] = []
        var follow = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else {
                    throw UsageError.message("\(argument) needs a value")
                }
                return arguments[index]
            }
            switch argument {
            case "--network":
                switch try value() {
                case "regtest": network = .regtest
                case "signet": network = .signet
                default: throw UsageError.message("--network needs regtest or signet")
                }
            case "--state": statePath = try value()
            case "--start-height":
                guard let number = UInt32(try value()) else {
                    throw UsageError.message("--start-height needs a block height")
                }
                startHeight = number
            case "--watch-script": scriptHex = try value()
            case "--funding-outpoint": outpointText = try value()
            case "--peer":
                let text = try value()
                guard let separator = text.lastIndex(of: ":"),
                      let port = UInt16(text[text.index(after: separator)...]),
                      port > 0 else {
                    throw UsageError.message("--peer needs host:port")
                }
                var host = String(text[..<separator])
                if host.hasPrefix("[") && host.hasSuffix("]") {
                    host.removeFirst()
                    host.removeLast()
                }
                guard !host.isEmpty else { throw UsageError.message("--peer needs a host") }
                peers.append(PeerEndpoint(host: host, port: port))
            case "--follow": follow = true
            case "--help", "-h": throw UsageError.message(Self.help)
            default: throw UsageError.message("unknown option \(argument)\n\(Self.help)")
            }
            index += 1
        }
        guard let statePath, let scriptHex else {
            throw UsageError.message(Self.help)
        }
        if network.network == .regtest && peers.isEmpty {
            throw UsageError.message("regtest needs at least one --peer host:port")
        }
        let script = try HexBytes.decode(scriptHex)
        guard !script.isEmpty, script.count <= 10_000 else {
            throw UsageError.message("--watch-script needs 1–10,000 bytes of hex")
        }
        self.network = network
        stateDirectory = URL(fileURLWithPath: statePath, isDirectory: true)
        self.startHeight = startHeight
        watch = ChannelWatch(scriptPubKey: script,
                             fundingOutpoint: try outpointText.map(FundingOutpoint.init(displayText:)))
        self.peers = peers
        self.follow = follow
    }

    static let help = """
    chain-watch --network regtest|signet --state DIR --watch-script SCRIPT_HEX [options]

    Read-only BIP157/158 channel funding and spend watcher.
    It connects directly to Bitcoin peers; no Bitcoin Core RPC is used.

      --network regtest|signet   Default regtest
      --funding-outpoint TXID:VOUT  Watch an exact channel output and its spend
      --start-height HEIGHT       First block to scan (default 0)
      --peer HOST:PORT            Add a Bitcoin peer (repeatable)
      --follow                    Keep scanning for new blocks
    """
}

@main
private struct ChainWatchApp {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            fputs("\(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ options: Options) async throws {
        let files = FileManager.default
        try files.createDirectory(at: options.stateDirectory, withIntermediateDirectories: true)
        let journal = try EventJournal(url: options.stateDirectory.appendingPathComponent("events.json"),
                                       network: options.network.network.rawValue, watch: options.watch)
        try await journal.ensureStored()
        let chain = try HeaderChain(params: options.network,
                                    storageURL: options.stateDirectory.appendingPathComponent("headers.dat"))
        let desiredPeers = options.network.network == .regtest ? max(1, options.peers.count) : max(3, options.peers.count)
        let pool = PeerPool(params: options.network, peerCount: desiredPeers,
                            manualPeers: options.peers,
                            peersFileURL: options.stateDirectory.appendingPathComponent("peers.json"))
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: options.startHeight,
                                     storageURL: options.stateDirectory.appendingPathComponent("filters.json"))
        await pool.start()
        do {
            repeat {
                try await filters.sync(watchScripts: [options.watch.scriptPubKey],
                                       onReorg: { forkHeight in
                                           try await journal.rollBack(to: forkHeight)
                                           print("reorg: kept blocks through height \(forkHeight)")
                                       },
                                       onMatch: { match in
                                           let found = options.watch.events(height: match.height,
                                                                            transactions: match.block.transactions)
                                           let added = try await journal.record(found)
                                           let encoder = JSONEncoder()
                                           encoder.outputFormatting = [.sortedKeys]
                                           for event in added {
                                               let data = try encoder.encode(event)
                                               print(String(decoding: data, as: UTF8.self))
                                           }
                                       })
                let height = await chain.height
                let frontier = await filters.nextScanHeight
                print("scanned \(options.network.network.rawValue) through height \(height); next \(frontier)")
                if options.follow { try await Task.sleep(for: .seconds(10)) }
            } while options.follow && !Task.isCancelled
        } catch {
            await pool.stop()
            throw error
        }
        await pool.stop()
    }
}
