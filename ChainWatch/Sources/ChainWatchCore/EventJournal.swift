import Foundation

/// Persists observations before FilterSync advances its scan frontier.
/// A reorg removes observations on the disconnected branch before rescanning.
public actor EventJournal {
    private struct Stored: Codable {
        let network: String
        let scriptHex: String
        let outpoint: String?
        var events: [WatchedEvent]
    }

    private let url: URL
    private var stored: Stored

    public init(url: URL, network: String, watch: ChannelWatch) throws {
        self.url = url
        let scriptHex = HexBytes.encode(watch.scriptPubKey)
        let outpoint = watch.fundingOutpoint?.displayText
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Stored.self, from: data)
            guard decoded.network == network,
                  decoded.scriptHex == scriptHex, decoded.outpoint == outpoint else {
                throw ChainWatchError.changedWatch
            }
            stored = decoded
        } else {
            stored = Stored(network: network, scriptHex: scriptHex, outpoint: outpoint, events: [])
        }
    }

    public func events() -> [WatchedEvent] { stored.events }

    public func ensureStored() throws { try persist(stored) }

    @discardableResult
    public func record(_ events: [WatchedEvent]) throws -> [WatchedEvent] {
        let added = events.filter { !stored.events.contains($0) }
        guard !added.isEmpty else { return [] }
        var next = stored
        next.events.append(contentsOf: added)
        try persist(next)
        stored = next
        return added
    }

    public func rollBack(to forkHeight: UInt32) throws {
        var next = stored
        next.events.removeAll { $0.height > forkHeight }
        try persist(next)
        stored = next
    }

    private func persist(_ next: Stored) throws {
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
