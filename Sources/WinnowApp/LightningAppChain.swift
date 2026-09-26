import Foundation
import LightningCore
import WalletCore

extension AppModel {
    /// One verified filter scan applies both wallet matches and channel
    /// observations. No separate Bitcoin node, RPC wallet or chain model.
    func syncWalletAndLightning(filters: FilterSync, scripts: [Data],
                                onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws {
        guard let lightning else {
            try await filters.sync(watchScripts: scripts, onReorg: onReorg, onMatch: onMatch)
            return
        }
        let generation = lightning.generation
        guard let driver = lightning.driver else { throw AppError.noStack }
        let complete = try await driver.sync(using: filters, walletScripts: scripts, onEvent: { [weak self] events in
            guard let self else { throw CancellationError() }
            try await lightning.requireNetwork(self, generation: generation)
            try await lightning.handle(events, model: self)
        }, onReorg: onReorg, onMatch: onMatch)
        try lightning.requireNetwork(self, generation: generation)
        if complete { await lightning.resume(model: self) }
    }
}
