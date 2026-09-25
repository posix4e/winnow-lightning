import Foundation
import WalletCore

/// The engine adds watch scripts to Winnow's verified scanner. It never opens
/// a second Bitcoin connection or treats a remote channel_ready as funding.
public actor LightningChainDriver {
    private let engine: LightningEngine
    private let headers: HeaderChain
    private var syncing = false
    public init(engine: LightningEngine, headers: HeaderChain) { self.engine = engine; self.headers = headers }

    @discardableResult
    public func sync(using filters: FilterSync, walletScripts: [Data], maxBlocks: UInt32? = nil,
                     onEvent: @escaping @Sendable ([LightningEngine.Event]) async throws -> Void,
                     onReorg: (@Sendable (UInt32) async throws -> Void)? = nil,
                     onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        guard !syncing else { throw LightningChainError.busy }
        syncing = true
        defer { syncing = false }
        try await prepare(onReorg: onReorg)
        let observer = FilterScanObserver(watches: { try await self.engine.chainWatches() }, scanned: { scanned in
            guard await self.headers.blockHash(at: scanned.height) == scanned.header.hash else { throw LightningChainError.restartScan }
            // Persist historical observations without publishing financial
            // actions until every verified height has been inspected.
            _ = try await self.engine.scannedBlock(scanned)
        })
        let complete = try await scan(using: filters, walletScripts: walletScripts, maxBlocks: maxBlocks, observer: observer, onReorg: onReorg, onMatch: onMatch)
        if complete { try await onEvent(engine.pendingChainEvents()) }
        return complete
    }
    private func prepare(onReorg: (@Sendable (UInt32) async throws -> Void)?) async throws {
        await engine.chainDisconnected()
        if await engine.chainStatus().rescanRequired {
            guard let genesis = await headers.blockHash(at: 0) else { throw LightningChainError.missingHeader }
            try await onReorg?(0)
            try await engine.blocksDisconnected(to: 0, hash: genesis)
        }
        try await reconcileAncestry(onReorg: onReorg)
    }
    private func scan(using filters: FilterSync, walletScripts: [Data], maxBlocks: UInt32?, observer: FilterScanObserver,
                      onReorg: (@Sendable (UInt32) async throws -> Void)?,
                      onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        for _ in 0..<32 {
            let status = await engine.chainStatus()
            if await filters.nextScanHeight > status.nextHeight { try await filters.rollBack(to: status.nextHeight - 1) }
            do {
                try await filters.sync(watchScripts: walletScripts, maxBlocks: maxBlocks, observer: observer,
                    onReorg: { height in
                        try await onReorg?(height)
                        guard let hash = await self.headers.blockHash(at: height) else { throw LightningChainError.missingHeader }
                        try await self.engine.blocksDisconnected(to: height, hash: hash)
                    }, onMatch: onMatch)
            } catch LightningChainError.changedWatches { continue }
              catch LightningChainError.restartScan { continue }
            let height = await headers.height
            if await engine.chainStatus().nextHeight > height {
                try await engine.chainCaughtUp(height: height)
                return true
            }
            if maxBlocks != nil { return false }
        }
        throw LightningChainError.catchUpDidNotConverge
    }
    private func reconcileAncestry(onReorg: (@Sendable (UInt32) async throws -> Void)?) async throws {
        let positions = await engine.chainStatus().positions
        guard let last = positions.last, await headers.blockHash(at: last.height) != last.hash else { return }
        for position in positions.reversed() where await headers.blockHash(at: position.height) == position.hash {
            try await onReorg?(position.height)
            try await engine.blocksDisconnected(to: position.height, hash: position.hash)
            return
        }
        if positions.first?.height == 1, let genesis = await headers.blockHash(at: 0) {
            try await onReorg?(0)
            try await engine.blocksDisconnected(to: 0, hash: genesis)
            return
        }
        throw LightningChainError.recoveryRequired
    }
}
