import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct FundingReview {
        let request: LightningEngine.FundingRequest
        let preview: AppModel.SendPreview
    }
    static func commitmentFeeRate(satPerVByte rate: Double) throws -> UInt32 {
        guard rate.isFinite, rate > 0, rate <= 400 else { throw LightningError.invalidAmount }
        return max(253, UInt32((rate * 250).rounded(.up)))
    }
    func openChannel(capacitySat: UInt64, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, let profile, await engine.channels().isEmpty else { throw LightningError.invalidState }
            let rate = try Self.commitmentFeeRate(satPerVByte: await model.resolvedFeeRate(priority: .medium, override: nil))
            try requireNetwork(model, generation: epoch)
            _ = try await engine.openChannel(peer: profile.peerKey, capacitySat: capacitySat, feePerKW: rate)
            try await refresh()
        }
    }
    func reviewFunding(_ request: LightningEngine.FundingRequest, model: AppModel) async throws -> FundingReview {
        try requireNetwork(model)
        guard let wallet = model.wallet,
              let destination = AddressDecoder.address(for: request.scriptPubKey, network: network) else { throw LightningError.invalidMessage }
        let preview: AppModel.SendPreview
        if let reserved = await wallet.fundingReservations.first(where: { $0.requestID == request.temporaryID.hex }) {
            guard reserved.phase == .reserved, reserved.amount == Int64(request.amountSat), reserved.scriptPubKey == request.scriptPubKey else {
                throw LightningError.invalidState
            }
            let tx = try reserved.transaction(), change = try reserved.changeOutput()
            preview = AppModel.SendPreview(destination: destination, payments: [.init(amount: reserved.amount, scriptPubKey: reserved.scriptPubKey)],
                feeRateSatPerVByte: reserved.feeRateSatPerVByte, fee: reserved.fee, changeAmount: change?.value, inputCount: tx.inputs.count,
                selectedOutpoints: tx.inputs.map { .init(txid: $0.previousOutput.txid, vout: $0.previousOutput.vout) },
                change: change.map { .init(amount: $0.value, scriptPubKey: $0.scriptPubKey) })
        } else {
            preview = try await model.previewSend(destination: destination, amount: Int64(request.amountSat), priority: .medium, override: nil)
        }
        return FundingReview(request: request, preview: preview)
    }
    func fund(_ review: FundingReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, let wallet = model.wallet, try await engine.fundingRequests().contains(review.request) else { throw LightningError.invalidState }
            try await model.authenticateSensitiveAction(reason: "Fund this \(network.rawValue) Lightning channel")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            guard await engine.isChainCurrent() else { throw LightningError.invalidState }
            let request = review.request, preview = review.preview
            let reservation = try await wallet.reserveChannelFunding(requestID: request.temporaryID.hex, amount: Int64(request.amountSat),
                scriptPubKey: request.scriptPubKey, feeRateSatPerVByte: preview.feeRateSatPerVByte, chainTip: model.chainTipHeight)
            guard try preview.authorizes(transaction: reservation.transaction(), fee: reservation.fee, changeAmount: reservation.changeOutput()?.value) else {
                try await wallet.cancelUnsubmittedFunding(requestID: reservation.requestID)
                throw AppModel.AppError.sendReviewChanged
            }
            let submitted = try await wallet.markFundingSubmitted(requestID: reservation.requestID)
            try await supply(submitted, request: request, engine: engine)
            try await refresh()
        }
    }
    func resumeSubmittedFunding(model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard let engine, let wallet = model.wallet else { return }
        let requests = try await engine.fundingRequests()
        for reservation in await wallet.fundingReservations where reservation.phase == .submitted {
            try requireNetwork(model, generation: epoch)
            if let request = requests.first(where: { $0.temporaryID.hex == reservation.requestID }) {
                try await supply(reservation, request: request, engine: engine)
            }
        }
        try await handle(engine.pendingFundingBroadcasts(), model: model)
    }
    private func supply(_ reservation: FundingReservation, request: LightningEngine.FundingRequest, engine: LightningEngine) async throws {
        let tx = try reservation.transaction()
        guard reservation.phase == .submitted, reservation.amount == Int64(request.amountSat), reservation.scriptPubKey == request.scriptPubKey,
              let index = tx.outputs.firstIndex(where: { $0.scriptPubKey == request.scriptPubKey && $0.value == Int64(request.amountSat) }),
              let output = UInt16(exactly: index) else { throw LightningError.invalidMessage }
        try await engine.provideFunding(temporaryID: request.temporaryID, peer: request.peer, transaction: tx, output: output)
    }
}
