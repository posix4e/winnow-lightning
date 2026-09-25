import Foundation
import WalletCore

public enum LightningChainError: Error, Equatable {
    case busy, changedWatches, restartScan, missingHeader, recoveryRequired, catchUpDidNotConverge
}

/// Runs additional consumers through Winnow's existing scanner. There is no
/// Bitcoin network client here. The array supports two local test engines;
/// the app supplies its one engine and the same scanner used by its wallet.
public actor LightningChainDriver {
    private let engines: [LightningEngine]
    private let headers: HeaderChain
    private var syncing = false
    private var ticket: UInt64 = 0
    private var revisions: [UInt64] = []

    public init(engines: [LightningEngine], headers: HeaderChain) {
        self.engines = engines
        self.headers = headers
    }

    /// `onUpdate` must consume returned Lightning packets without losing them.
    /// Broadcast events stay durable until the caller explicitly acknowledges
    /// acceptance by Winnow's broadcaster. It must wait for `chain_ready`.
    @discardableResult
    public func sync(using filters: FilterSync, walletScripts: [Data], maxBlocks: UInt32? = nil,
                     onUpdate: @escaping @Sendable (Int, LightningSnapshot) async throws -> Void,
                     onReorg: (@Sendable (UInt32) async throws -> Void)? = nil,
                     onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        guard !syncing else { throw LightningChainError.busy }
        syncing = true
        defer { syncing = false }
        let observer = FilterScanObserver(watches: { try await self.watches(onUpdate: onUpdate, onReorg: onReorg) }, scanned: {
            try await self.scanned($0, onUpdate: onUpdate)
        })
        for _ in 0..<32 {
            var earliest = UInt32.max
            for engine in engines { earliest = min(earliest, try await engine.status().scan_next) }
            if earliest > 0, earliest < UInt32.max, await filters.nextScanHeight > earliest {
                try await filters.rollBack(to: earliest - 1)
            }
            do {
                try await filters.sync(watchScripts: walletScripts, maxBlocks: maxBlocks, observer: observer,
                    onReorg: { fork in
                        try await onReorg?(fork)
                        try await self.rollback(to: fork, onUpdate: onUpdate)
                    }, onMatch: onMatch)
            } catch LightningChainError.changedWatches { continue }
              catch LightningChainError.restartScan { continue }
              catch LightningError.native("watch revision changed") { continue }
              catch LightningError.native("scan restart required") { continue }
            let tip = await headers.height
            var caughtUp = true
            var mustReplay = false
            for engine in engines {
                let snapshot = try await engine.status()
                caughtUp = caughtUp && snapshot.scan_next > tip
                mustReplay = mustReplay || !snapshot.chain_ready
            }
            if caughtUp || (maxBlocks != nil && !mustReplay) { return caughtUp }
        }
        throw LightningChainError.catchUpDidNotConverge
    }

    private func watches(onUpdate: @escaping @Sendable (Int, LightningSnapshot) async throws -> Void,
                         onReorg: (@Sendable (UInt32) async throws -> Void)?) async throws -> FilterWatchSet {
        var scripts = Set<Data>()
        var observed: [UInt64] = []
        for engine in engines {
            let snapshot = try await engine.status()
            for position in snapshot.chain_positions {
                guard let expected = Data(hex: position.block_hash), expected.count == 32 else {
                    throw LightningError.invalidResponse
                }
                if await headers.blockHash(at: position.height) != Data(expected.reversed()) {
                    // A prior process may have saved the new Winnow header chain
                    // before saving every consumer's rollback. Recover from the
                    // persisted locator; never guess beyond its ancestry window.
                    var fork: UInt32?
                    for (offset, ancestor) in position.previous_blocks.enumerated() {
                        guard position.height > UInt32(offset), let ancestor,
                              let hash = Data(hex: ancestor) else { continue }
                        let height = position.height - UInt32(offset) - 1
                        if await headers.blockHash(at: height) == Data(hash.reversed()) {
                            fork = height
                            break
                        }
                    }
                    guard let fork else { throw LightningChainError.recoveryRequired }
                    try await onReorg?(fork)
                    try await rollback(to: fork, onUpdate: onUpdate)
                    throw LightningChainError.restartScan
                }
            }
            observed.append(snapshot.watch_revision)
            for watch in snapshot.watches.values {
                guard let script = Data(hex: watch.script) else { throw LightningError.invalidResponse }
                scripts.insert(script)
            }
        }
        guard ticket < UInt64.max else { throw LightningChainError.recoveryRequired }
        ticket += 1
        revisions = observed
        return FilterWatchSet(scripts: Array(scripts), revision: ticket)
    }

    private func scanned(_ block: FilterScannedBlock,
                         onUpdate: @Sendable (Int, LightningSnapshot) async throws -> Void) async throws {
        guard block.watchRevision == ticket, revisions.count == engines.count else { throw LightningChainError.changedWatches }
        let expected = revisions
        for (index, engine) in engines.enumerated() {
            let snapshot = try await engine.status()
            guard snapshot.watch_revision == expected[index] else { throw LightningChainError.changedWatches }
            // Native state is saved per height; FilterSync saves per batch.
            // A failed batch can therefore repeat heights already accepted.
            if block.height < snapshot.scan_next { continue }
            guard block.height == snapshot.scan_next else { throw LightningChainError.restartScan }
            let result = try await engine.scannedBlock(header: block.header, block: block.block,
                                                       height: block.height, watchRevision: expected[index])
            try await onUpdate(index, result)
        }
    }

    private func rollback(to height: UInt32,
                          onUpdate: @Sendable (Int, LightningSnapshot) async throws -> Void) async throws {
        guard let hash = await headers.blockHash(at: height) else { throw LightningChainError.missingHeader }
        for (index, engine) in engines.enumerated() {
            if try await engine.status().chain_positions.contains(where: { $0.height > height }) {
                let result = try await engine.blocksDisconnected(blockHash: hash, height: height)
                try await onUpdate(index, result)
            }
        }
    }
}
