import Foundation
import CLightningBridge
import WalletCore

public enum LightningError: Error, Equatable, LocalizedError {
    case invalidSeed, invalidFee, closed, invalidResponse, native(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSeed: "Invalid Lightning seed."
        case .invalidFee: "Invalid Lightning fee rate."
        case .closed: "Unlock the Lightning session before continuing."
        case .invalidResponse: "The Lightning request or response is invalid."
        case .native(let message): message
        }
    }
}

/// Values crossing ABI 1. Bitcoin hashes use display hex; transaction and
/// script strings contain unmodified consensus bytes. Amounts name their unit.
public struct LightningSnapshot: Decodable, Sendable {
    public let abi: Int
    public let core_revision: String
    public let network: String
    public let node_id: String
    public let kem_key: String
    public let signature_key: String
    public let height: UInt32
    public let block_hash: String
    public let watch_revision: UInt64
    public let scan_next: UInt32
    public let chain_ready: Bool
    public let chain_positions: [LightningChainPosition]
    public let events: [String: LightningEvent]
    public let watches: [String: LightningWatch]
    public let invoices: [String: LightningInvoice]
    public let hash_invoices: [String: LightningHashInvoice]
    public let payments: [String: LightningPayment]
    public let sweeps: [String: LightningSweep]
    public let close_destinations: [String: String]
    public let peers: [String]
    public let channels: [LightningChannel]
    public let packets: [LightningPacket]?
    public let inspected_claim: LightningClaimInspection?
    public let exported_claim: String?
    public let claims: [String: LightningClaim]
    public let capabilities: LightningCapabilities
    public let peer_pin: LightningPeerPin?
}

public struct LightningPeerPin: Decodable, Sendable {
    public let kem_key: String
    public let signature_key: String
}

public struct LightningCapabilities: Decodable, Sendable {
    public let supplied_hash_invoices: Bool
    public let onion_messages: Bool
    public let bolt12_refund_payments: Bool
    public let funded_claims: Bool
}

public struct LightningClaim: Decodable, Sendable {
    public let claim_id: String
    public let request_id: String?
    public let direction: String
    public let amount_msat: UInt64
    public let provider: String
    public let state: String
    public let terms: LightningClaimInspection?
    public let quote_commitment: String?
    public let last_error: String?
}

public struct LightningClaimProvider: Encodable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

/// Authenticated public terms only; inspecting never imports, connects or pays.
public struct LightningClaimInspection: Decodable, Sendable {
    public let version: UInt8
    public let network: String
    public let claim_id: String
    public let provider_node_id: String
    public let provider_host: String
    public let provider_port: UInt16
    public let payment_hash: String
    public let amount_msat: UInt64
    public let fee_msat: UInt64
    public let latest_claim_height: UInt32
    public let expires_at_unix: UInt64
}

public struct LightningSweep: Decodable, Sendable {
    public let script: String
    public let transaction: String
}
public struct LightningInvoice: Decodable, Sendable {
    public let invoice: String
    public let amount_msat: UInt64
    public let payment_hash: String
}
public struct LightningHashInvoice: Decodable, Sendable {
    public let request_id: String
    public let amount_msat: UInt64
    public let payment_hash: String
    public let invoice: String?
    public let state: String
    public let claim_deadline: UInt32?
}
public struct LightningPayment: Decodable, Sendable {
    public let invoice: String
    public let amount_msat: UInt64
    public let max_fee_msat: UInt64
    public let state: String
    public let fee_paid_msat: UInt64?
}
public struct LightningChainPosition: Decodable, Sendable {
    public let height: UInt32
    public let block_hash: String
    public let previous_blocks: [String?]
}

public struct LightningEvent: Decodable, Sendable {
    public let kind: String
    public let temporary_channel_id: String?
    public let node_id: String?
    public let amount_sat: Int64?
    public let script: String?
    public let transactions: [String]?
    public let channel_id: String?
    public let payment_hash: String?
    public let output_id: String?
    public let amount_msat: UInt64?
    public let fee_paid_msat: UInt64?

    public var fundingRequestID: String? {
        // Winnow's bounded request identifier: channel ids are random 32-byte
        // values. The native event also binds this id to the counterparty.
        guard kind == "funding", let temporary_channel_id,
              Data(hex: temporary_channel_id)?.count == 32 else { return nil }
        return temporary_channel_id
    }
}
public struct LightningWatch: Decodable, Sendable {
    public let txid: String
    public let vout: UInt32?
    public let script: String
    public let block_hash: String?
}
public struct LightningChannel: Decodable, Sendable {
    public let channel_id: String
    public let node_id: String
    public let amount_sat: Int64
    public let ready: Bool
    public let usable: Bool
    public let funding_txid: String?
    public let outbound_htlcs: [LightningHTLC]
    public let outbound_capacity_msat: UInt64
    public let inbound_capacity_msat: UInt64
}
public struct LightningHTLC: Decodable, Sendable {
    public let payment_hash: String
    public let amount_msat: UInt64
    public let cltv_expiry: UInt32
    public let is_dust: Bool
    public let committed: Bool
}
public struct LightningPacket: Decodable, Sendable {
    public let connection: UInt64
    public let sequence: UInt64
    public let bytes: String
    public let resume_read: Bool
    public let closed: Bool
}

/// One Swift actor owns an opaque native engine. Rust callbacks never enter
/// Swift: synchronous monitor persistence stays native, while Swift drains
/// protocol I/O and durable requests after the call has returned.
public actor LightningEngine {
    private var handle: UInt64

    public init(seed: Data, storageURL: URL, network: BitcoinNetwork,
                feeRateSatPerVByte: Double, allowPrivateForwarding: Bool = false,
                enableClaims: Bool = false, claimProvider: LightningClaimProvider? = nil) throws {
        guard seed.count == 32 else { throw LightningError.invalidSeed }
        let fee = try Self.satPerKW(feeRateSatPerVByte)
        let configuration = Configuration(network: network.rawValue, storage_path: storageURL.path,
            fee_sat_per_kw: fee, allow_private_forwarding: allowPrivateForwarding,
            enable_claims: enableClaims, claim_provider: claimProvider)
        let data = try JSONEncoder().encode(configuration)
        var output = WlnBuffer(bytes: nil, length: 0)
        let code = data.withUnsafeBytes { configBytes in
            seed.withUnsafeBytes { seedBytes in
                wln_create(configBytes.bindMemory(to: UInt8.self).baseAddress, data.count,
                           seedBytes.bindMemory(to: UInt8.self).baseAddress, seed.count, &output)
            }
        }
        let created: Created = try Self.decode(code: code, output: output)
        guard created.handle > 0, created.snapshot.abi == 1 else {
            wln_destroy(created.handle)
            throw LightningError.invalidResponse
        }
        handle = created.handle
    }

    deinit { wln_destroy(handle) }

    public func close() { wln_destroy(handle); handle = 0 }

    /// Explicit conversion: 1 vbyte = 4 weight units, so sat/kw = sat/vB * 250.
    public static func satPerKW(_ satPerVByte: Double) throws -> UInt32 {
        guard satPerVByte.isFinite, satPerVByte > 0, satPerVByte <= 10_000 else { throw LightningError.invalidFee }
        return max(253, UInt32((satPerVByte * 250).rounded(.up)))
    }

    public func status() throws -> LightningSnapshot { try call(Request(command: "status")) }
    public func peerKeys(nodeID: String) throws -> LightningPeerPin {
        guard let pin = try call(Request(command: "peer_keys", node_id: nodeID)).peer_pin else {
            throw LightningError.invalidResponse
        }
        return pin
    }
    public func createRefund(amountMsat: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "create_refund", amount_msat: amountMsat))
    }
    public func requestRefundPayment(_ refund: String) throws -> LightningSnapshot {
        guard refund.utf8.count <= 32_768 else { throw LightningError.invalidResponse }
        return try call(Request(command: "request_refund_payment", refund: refund))
    }
    public func inspectClaim(_ text: String) throws -> LightningClaimInspection {
        guard text.utf8.count <= 32_768,
              let inspection = try call(Request(command: "inspect_claim", claim: text)).inspected_claim else {
            throw LightningError.invalidResponse
        }
        return inspection
    }
    public func prepareClaim(requestID: String, provider: String, host: String, port: UInt16,
                             amountMsat: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "prepare_claim", request_id: requestID, amount_msat: amountMsat,
                         provider: provider, host: host, port: port))
    }
    public func commitClaim(_ claim: LightningClaim) throws -> LightningSnapshot {
        guard let commitment = claim.quote_commitment else { throw LightningError.invalidResponse }
        return try call(Request(command: "commit_claim", claim_id: claim.claim_id, quote_commitment: commitment))
    }
    public func exportClaim(id: String) throws -> String {
        guard let text = try call(Request(command: "export_claim", claim_id: id)).exported_claim else {
            throw LightningError.invalidResponse
        }
        return text
    }
    public func importClaim(_ text: String) throws -> LightningSnapshot {
        guard text.utf8.count <= 32_768 else { throw LightningError.invalidResponse }
        return try call(Request(command: "import_claim", claim: text))
    }
    public func redeemClaim(id: String) throws -> LightningSnapshot {
        try call(Request(command: "redeem_claim", claim_id: id))
    }
    public func cancelClaim(id: String) throws -> LightningSnapshot {
        try call(Request(command: "cancel_claim", claim_id: id))
    }
    public func drain() throws -> LightningSnapshot { try call(Request(command: "drain")) }
    public func pinPeer(nodeID: String, kemKey: String, signatureKey: String) throws -> LightningSnapshot {
        try call(Request(command: "pin_peer", node_id: nodeID, kem_key: kemKey, signature_key: signatureKey))
    }
    public func createInvoice(requestID: String, amountMsat: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "create_invoice", request_id: requestID, amount_msat: amountMsat))
    }
    public func createHashInvoice(requestID: String, amountMsat: UInt64, paymentHash: Data,
                                  preimage: Data?, expirySeconds: UInt32 = 3600,
                                  minFinalCLTVDelta: UInt16 = 0) throws -> LightningSnapshot {
        guard paymentHash.count == 32, preimage == nil || preimage?.count == 32 else {
            throw LightningError.invalidResponse
        }
        return try call(Request(command: "create_hash_invoice", request_id: requestID,
                                amount_msat: amountMsat, payment_hash: paymentHash.hex,
                                preimage: preimage?.hex, expiry_secs: expirySeconds,
                                min_final_cltv_delta: minFinalCLTVDelta))
    }
    /// Protocol test primitive. A complete authenticated bearer-claim protocol
    /// is required before the application can offer this operation to users.
    public func forwardHeldPayment(paymentHash: String, invoice: String,
                                   maxFeeMsat: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "forward_held_payment", invoice: invoice,
                         max_fee_msat: maxFeeMsat, payment_hash: paymentHash))
    }
    public func payInvoice(_ invoice: String, amountMsat: UInt64, maxFeeMsat: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "pay_invoice", amount_msat: amountMsat, invoice: invoice, max_fee_msat: maxFeeMsat))
    }
    public func setFeeRate(_ satPerVByte: Double) throws -> LightningSnapshot {
        try call(Request(command: "set_fee", sat_per_kw: Self.satPerKW(satPerVByte)))
    }
    public func tick() throws -> LightningSnapshot { try call(Request(command: "tick")) }
    public func accept(connection: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "accept", connection: connection))
    }
    public func connect(connection: UInt64, nodeID: String, kemKey: String) throws -> LightningSnapshot {
        try call(Request(command: "connect", connection: connection, node_id: nodeID, kem_key: kemKey))
    }
    public func read(connection: UInt64, bytes: Data) throws -> LightningSnapshot {
        try call(Request(command: "read", connection: connection, bytes: bytes.hex))
    }
    public func disconnect(connection: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "disconnect", connection: connection))
    }
    public func openChannel(nodeID: String, amountSat: UInt64, userChannelID: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "open_channel", node_id: nodeID, amount_sat: amountSat, user_channel_id: userChannelID))
    }
    public func submitFunding(request: LightningEvent, reservation: FundingReservation) throws -> LightningSnapshot {
        guard reservation.phase == .submitted,
              request.fundingRequestID == reservation.requestID,
              request.amount_sat == reservation.amount,
              request.script.flatMap({ Data(hex: $0) }) == reservation.scriptPubKey,
              let nodeID = request.node_id else { throw LightningError.invalidResponse }
        return try call(Request(command: "submit_funding", node_id: nodeID,
                                temporary_channel_id: reservation.requestID,
                                transaction: reservation.rawTransaction.hex))
    }
    public func closeChannel(_ channel: LightningChannel, destinationScript: Data) throws -> LightningSnapshot {
        try call(Request(command: "close_channel", node_id: channel.node_id,
                         channel_id: channel.channel_id, script: destinationScript.hex))
    }
    public func forceClose(_ channel: LightningChannel) throws -> LightningSnapshot {
        try call(Request(command: "force_close", node_id: channel.node_id, channel_id: channel.channel_id))
    }
    public func sweepOutputs(outputID: String, destinationScript: Data) throws -> LightningSnapshot {
        try call(Request(command: "sweep_outputs", event_id: outputID, script: destinationScript.hex))
    }
    public func acknowledge(eventID: String) throws -> LightningSnapshot {
        try call(Request(command: "acknowledge", event_id: eventID))
    }
    public func blockConnected(_ block: Block, height: UInt32) throws -> LightningSnapshot {
        try call(Request(command: "block_connected", block: block.serialized.hex, height: height))
    }
    public func scannedBlock(header: BlockHeader, block: Block?, height: UInt32,
                             watchRevision: UInt64) throws -> LightningSnapshot {
        try call(Request(command: "scanned_block", block: block?.serialized.hex, height: height,
                         header: header.serialized.hex, watch_revision: watchRevision))
    }
    public func blocksDisconnected(blockHash: Data, height: UInt32) throws -> LightningSnapshot {
        guard blockHash.count == 32 else { throw LightningError.invalidResponse }
        return try call(Request(command: "blocks_disconnected", height: height, block_hash: blockHash.displayHex))
    }

    private func call(_ request: Request) throws -> LightningSnapshot {
        guard handle != 0 else { throw LightningError.closed }
        let nativeHandle = handle
        let data = try JSONEncoder().encode(request)
        var output = WlnBuffer(bytes: nil, length: 0)
        let code = data.withUnsafeBytes {
            wln_call(nativeHandle, $0.bindMemory(to: UInt8.self).baseAddress, data.count, &output)
        }
        return try Self.decode(code: code, output: output)
    }

    private static func decode<T: Decodable>(code: Int32, output: WlnBuffer) throws -> T {
        defer { wln_buffer_free(output) }
        guard code >= 0, let bytes = output.bytes, output.length > 0, output.length <= 32_000_000 else {
            throw LightningError.invalidResponse
        }
        let response = try JSONDecoder().decode(Response<T>.self, from: Data(bytes: bytes, count: output.length))
        guard code == 0, response.ok, let result = response.result else {
            throw LightningError.native(response.error ?? "unknown native error")
        }
        return result
    }

    private struct Response<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: String? }
    private struct Created: Decodable { let handle: UInt64; let snapshot: LightningSnapshot }
    private struct Configuration: Encodable {
        let network: String
        let storage_path: String
        let fee_sat_per_kw: UInt32
        let allow_private_forwarding: Bool
        let enable_claims: Bool
        let claim_provider: LightningClaimProvider?
    }
    private struct Request: Encodable {
        let command: String
        var connection: UInt64? = nil
        var node_id: String? = nil
        var kem_key: String? = nil
        var bytes: String? = nil
        var amount_sat: UInt64? = nil
        var user_channel_id: UInt64? = nil
        var temporary_channel_id: String? = nil
        var transaction: String? = nil
        var event_id: String? = nil
        var block: String? = nil
        var height: UInt32? = nil
        var block_hash: String? = nil
        var header: String? = nil
        var watch_revision: UInt64? = nil
        var signature_key: String? = nil
        var request_id: String? = nil
        var amount_msat: UInt64? = nil
        var invoice: String? = nil
        var max_fee_msat: UInt64? = nil
        var channel_id: String? = nil
        var script: String? = nil
        var sat_per_kw: UInt32? = nil
        var payment_hash: String? = nil
        var preimage: String? = nil
        var expiry_secs: UInt32? = nil
        var min_final_cltv_delta: UInt16? = nil
        var claim: String? = nil
        var claim_id: String? = nil
        var quote_commitment: String? = nil
        var provider: String? = nil
        var host: String? = nil
        var port: UInt16? = nil
        var refund: String? = nil
    }
}
