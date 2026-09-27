import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct LiquidityQuote: Codable {
        let profile: LightningProfile
        let request: LightningLiquidity.Purchase
        var order: LightningLiquidity.Order
        let feeSat: UInt64
        var accepted = false
        var invoice: String { order.payment.bolt11?.invoice ?? "" }
        func isPayable(network: BitcoinNetwork, now: UInt64) -> Bool {
            accepted && (try? order.validate(request: request, network: network, now: now)) == feeSat
        }
    }
    var maximumReceivableSat: UInt64 { (invoiceCapacities.map(\.maximumMsat).max() ?? 0) / 1000 }

    func prepareLiquidity(model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight else { throw LightningError.invalidState }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        let epoch = generation
        await resume(model: model)
        try requireNetwork(model, generation: epoch)
        guard let profile, profile.liquidityProvider != nil, let session = liquiditySession else { throw LightningLiquidityError.unavailable }
        guard await session.status == .connected else { throw LightningLiquidityError.unavailable }
        let info: LightningLiquidity.Info
        if let base = LightningProviders.provider(profile)?.api { info = try await LightningLiquidityHTTP(base: base).info() }
        else { info = try await session.liquidityInfo() }
        try requireNetwork(model, generation: epoch)
        liquidityInfo = info
    }
    func quoteLiquidity(capacitySat: UInt64, model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight, let info = liquidityInfo, let profile,
              let session = liquiditySession, liquidityQuote?.accepted != true else { throw LightningError.invalidState }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        guard await session.status == .connected else { throw LightningLiquidityError.unavailable }
        let epoch = generation, request = try info.request(capacitySat: capacitySat, token: LightningProviders.provider(profile)?.token ?? "")
        let order: LightningLiquidity.Order
        if let base = LightningProviders.provider(profile)?.api {
            guard let node = Data(hex: nodeID) else { throw LightningError.invalidState }
            order = try await LightningLiquidityHTTP(base: base).order(request, nodeID: node)
        } else { order = try await session.liquidityOrder(request) }
        try requireNetwork(model, generation: epoch)
        let fee = try order.validate(request: request, network: network, now: Self.now)
        let quote = LiquidityQuote(profile: profile, request: request, order: order, feeSat: fee)
        try storeLiquidityQuote(quote)
        liquidityQuote = quote
    }
    func acceptLiquidityQuote(model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            guard var quote = liquidityQuote, quote.profile == profile else { throw LightningError.invalidState }
            let epoch = generation
            _ = try quote.order.validate(request: quote.request, network: network, now: Self.now)
            try await model.authenticateSensitiveAction(reason: "Approve the \(quote.feeSat)-sat Lightning setup fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            _ = try quote.order.validate(request: quote.request, network: network, now: Self.now)
            quote.accepted = true
            try storeLiquidityQuote(quote); liquidityQuote = quote
        }
    }
    func refreshLiquidityOrder(model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight, var quote = liquidityQuote, let session = liquiditySession else { throw LightningError.invalidState }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        let epoch = generation
        let order: LightningLiquidity.Order
        if let base = LightningProviders.provider(profile)?.api { order = try await LightningLiquidityHTTP(base: base).status(id: quote.order.orderId) }
        else { order = try await session.liquidityOrderStatus(id: quote.order.orderId) }
        try requireNetwork(model, generation: epoch)
        guard order.orderId == quote.order.orderId, order.lspBalanceSat == quote.request.lspBalanceSat,
              order.clientBalanceSat == "0", !order.announceChannel,
              order.requiredChannelConfirmations == quote.request.requiredChannelConfirmations,
              order.fundingConfirmsWithinBlocks == quote.request.fundingConfirmsWithinBlocks,
              order.channelExpiryBlocks == quote.request.channelExpiryBlocks,
              order.payment.bolt11?.invoice == quote.invoice else { throw LightningError.invalidMessage }
        quote.order = order
        if order.orderState == "FAILED" { quote.accepted = false }
        try storeLiquidityQuote(quote); liquidityQuote = quote
        await model.syncNow(); try await refresh()
    }
    func createReceiveInvoice(amountSat: UInt64, model: AppModel) async throws -> String {
        try requireNetwork(model)
        guard let engine, let profile, connection == "Connected" else { throw LightningError.invalidState }
        return try await engine.createInvoice(id: Self.freshID(), peer: profile.peerKey, amountSat: amountSat, network: network, now: Self.now)
    }
}
