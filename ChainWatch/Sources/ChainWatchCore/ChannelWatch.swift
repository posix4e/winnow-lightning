import WalletCore
import Foundation

public enum ChainWatchError: Error, Equatable {
    case invalidHex
    case invalidOutpoint
    case changedWatch
}

public enum HexBytes {
    public static func decode(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw ChainWatchError.invalidHex }
        var bytes = Data()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                throw ChainWatchError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func displayHash(_ internalBytes: Data) -> String {
        encode(Data(internalBytes.reversed()))
    }
}

public struct FundingOutpoint: Codable, Equatable, Sendable {
    public let txid: Data // Bitcoin wire order
    public let vout: UInt32

    public init(txid: Data, vout: UInt32) throws {
        guard txid.count == 32 else { throw ChainWatchError.invalidOutpoint }
        self.txid = txid
        self.vout = vout
    }

    public init(displayText: String) throws {
        let parts = displayText.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let vout = UInt32(parts[1]),
              parts[0].count == 64 else { throw ChainWatchError.invalidOutpoint }
        let displayBytes = try HexBytes.decode(String(parts[0]))
        try self.init(txid: Data(displayBytes.reversed()), vout: vout)
    }

    public var displayText: String { "\(HexBytes.displayHash(txid)):\(vout)" }
}

public struct WatchedEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case fundingOutput, fundingSpend }

    public let kind: Kind
    public let height: UInt32
    public let transactionID: String
    public let vout: UInt32?
    public let amountSats: Int64?

    public init(kind: Kind, height: UInt32, transactionID: String,
                vout: UInt32? = nil, amountSats: Int64? = nil) {
        self.kind = kind
        self.height = height
        self.transactionID = transactionID
        self.vout = vout
        self.amountSats = amountSats
    }
}

/// Turns a compact-filter matched block into channel funding and spend observations.
/// The caller supplies the funding script learned from LDK; no wallet keys are needed.
public struct ChannelWatch: Sendable {
    public let scriptPubKey: Data
    public let fundingOutpoint: FundingOutpoint?

    public init(scriptPubKey: Data, fundingOutpoint: FundingOutpoint? = nil) {
        self.scriptPubKey = scriptPubKey
        self.fundingOutpoint = fundingOutpoint
    }

    public func events(height: UInt32, transactions: [Transaction]) -> [WatchedEvent] {
        var events: [WatchedEvent] = []
        for transaction in transactions {
            let transactionID = HexBytes.displayHash(transaction.txid)
            for (vout, output) in transaction.outputs.enumerated() where output.scriptPubKey == scriptPubKey {
                if let fundingOutpoint,
                   (fundingOutpoint.txid != transaction.txid || fundingOutpoint.vout != UInt32(vout)) {
                    continue
                }
                events.append(WatchedEvent(kind: .fundingOutput, height: height,
                                           transactionID: transactionID, vout: UInt32(vout),
                                           amountSats: output.value))
            }
            if let fundingOutpoint,
               transaction.inputs.contains(where: {
                   $0.previousOutput.txid == fundingOutpoint.txid &&
                   $0.previousOutput.vout == fundingOutpoint.vout
               }) {
                events.append(WatchedEvent(kind: .fundingSpend, height: height,
                                           transactionID: transactionID))
            }
        }
        return events
    }
}
