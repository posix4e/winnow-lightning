import Foundation
import WalletCore

extension Bolt11Invoice {
    public struct Decoded: Sendable {
        public let amountMsat: UInt64?, paymentHash: Data, paymentSecret: Data?, payee: Data
        public let timestamp: UInt64, expirySeconds: UInt64
        public var expiresAt: UInt64 { timestamp + expirySeconds }
    }
    public static func decode(_ string: String, network: BitcoinNetwork) throws -> Decoded {
        let (hrp, words, encoding) = try Bech32.decode(string, maxLength: 8192)
        guard encoding == .bech32, words.count >= 111 else { throw LightningError.invalidMessage }
        let amount = try amount(hrp, network: network)
        let unsigned = Array(words.dropLast(104)), signature = Data(try SegwitAddress.convertBits(Array(words.suffix(104)), from: 5, to: 8, pad: false))
        let fields = try fields(Array(unsigned.dropFirst(7)))
        let hash = try bytes(fields, type: 1, count: 32)
        let secret = fields[16] == nil ? nil : try bytes(fields, type: 16, count: 32)
        guard (fields[13] != nil) != (fields[23] != nil) else { throw LightningError.invalidMessage }
        let digest = ChannelKeys.hash(Data(hrp.utf8) + Data(try SegwitAddress.convertBits(unsigned, from: 5, to: 8, pad: true)))
        let payee = try recover(signature: signature, digest: digest)
        if fields[19] != nil { guard try bytes(fields, type: 19, count: 33) == payee else { throw LightningError.invalidSignature } }
        let expiry = try number(fields[6] ?? integer(3600))
        let timestamp = try number(Array(words.prefix(7)))
        guard expiry <= UInt64.max - timestamp else { throw LightningError.invalidMessage }
        return Decoded(amountMsat: amount, paymentHash: hash, paymentSecret: secret, payee: payee, timestamp: timestamp, expirySeconds: expiry)
    }
    private static func amount(_ hrp: String, network: BitcoinNetwork) throws -> UInt64? {
        let prefix = prefix(network: network)
        guard hrp.hasPrefix(prefix) else { throw LightningError.invalidMessage }
        var digits = String(hrp.dropFirst(prefix.count))
        if digits.isEmpty { return nil }
        let multiplier = digits.last!
        let factor: UInt64
        switch multiplier {
        case "m": factor = 100_000_000; digits.removeLast()
        case "u": factor = 100_000; digits.removeLast()
        case "n": factor = 100; digits.removeLast()
        case "p": factor = 1; digits.removeLast()
        default: factor = 100_000_000_000
        }
        guard digits.first != "0", digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(digits), value > 0, value <= UInt64.max / factor else { throw LightningError.invalidAmount }
        if multiplier == "p" {
            guard value % 10 == 0 else { throw LightningError.invalidAmount }
            return value / 10
        }
        return value * factor
    }
    private static func fields(_ words: [UInt8]) throws -> [UInt8: [UInt8]] {
        var offset = 0, result: [UInt8: [UInt8]] = [:]
        while offset < words.count {
            guard words.count - offset >= 3 else { throw LightningError.invalidMessage }
            let type = words[offset], length = Int(words[offset + 1]) * 32 + Int(words[offset + 2]); offset += 3
            guard length <= words.count - offset else { throw LightningError.invalidMessage }
            if [1, 16, 13, 23, 19, 6, 24, 5].contains(type) {
                guard result[type] == nil else { throw LightningError.invalidMessage }
                result[type] = Array(words[offset..<(offset + length)])
            }
            offset += length
        }
        return result
    }
    private static func bytes(_ fields: [UInt8: [UInt8]], type: UInt8, count: Int) throws -> Data {
        guard let words = fields[type] else { throw LightningError.invalidMessage }
        let data = Data(try SegwitAddress.convertBits(words, from: 5, to: 8, pad: false))
        guard data.count == count else { throw LightningError.invalidMessage }
        return data
    }
    private static func number(_ words: [UInt8]) throws -> UInt64 {
        guard words.count <= 13 else { throw LightningError.invalidAmount }
        var value: UInt64 = 0
        for word in words {
            guard value <= UInt64.max >> 5 else { throw LightningError.invalidAmount }
            value = (value << 5) | UInt64(word)
        }
        return value
    }
}
