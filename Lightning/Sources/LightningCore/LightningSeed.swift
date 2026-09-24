import CryptoKit
import Foundation
import WalletCore

/// Version 1: HKDF-SHA256(master private key || chain code,
/// salt="winnow/lightning/seed/v1", info=network.rawValue, length=32).
/// This derives only the node identity. Channel records remain indispensable.
public enum LightningSeed {
    public static func deriveV1(secret: WalletSecret, network: BitcoinNetwork) throws -> Data {
        let master: HDKey
        switch secret {
        case .mnemonic(let words): master = try HDKey(seed: BIP39.seed(mnemonic: words))
        case .masterKey(let xprv): master = try HDKey.deserialize(xprv)
        }
        guard let key = master.privateKey else { throw LightningError.invalidSeed }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key + master.chainCode),
            salt: Data("winnow/lightning/seed/v1".utf8), info: Data(network.rawValue.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }
}
