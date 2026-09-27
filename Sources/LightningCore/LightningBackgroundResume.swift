import Foundation

extension LightningEngine {
    /// Call after stopping the background monitor and before any peer resumes.
    /// Background may already have published our last signed commitment.
    public func resumeFromBackground() throws {
        try healthy()
        guard let backgroundStore else { return }
        // Older apps must refuse this journal BEFORE a locked monitor can
        // broadcast. Upgrade the format without changing any channel state.
        // If this write fails there is still no recovery plan to run.
        if needsBackgroundSchemaUpgrade {
            do { try journal.store(JSONEncoder().encode(state)); needsBackgroundSchemaUpgrade = false }
            catch { failed = true; throw LightningError.storageFailed }
        }
        var next = state
        if let snapshot = try backgroundStore.load() {
            guard snapshot.version == 1, snapshot.chain == state.chain, snapshot.revision == state.revision
            else { failed = true; throw LightningError.storageFailed }
            for recovery in snapshot.channels {
                guard let raw = recovery.closingIntent else { continue }
                guard let index = next.channels.firstIndex(where: { $0.id == recovery.id }),
                      !next.channels[index].dataLossDetected,
                      raw == next.channels[index].signedCommitment || raw == next.channels[index].closingTransaction
                else { failed = true; throw LightningError.storageFailed }
                next.channels[index].closingTransaction = raw
                next.channels[index].phase = .closing
                _ = markPaymentsRecovering(channelID: recovery.id, in: &next)
                next.outbox.removeAll { $0.channelID == recovery.id }
            }
            // Keep the full engine's older scan frontier: it must replay all
            // background observations before allowing protocol work again.
        }
        try persist(next)
    }
}
