import Foundation
import Testing
import WalletCore
import TestSupport
@testable import LightningCore

@Suite("Separated Lightning identity")
struct LightningSeedTests {
    @Test("Mnemonic and master-key imports derive the same versioned identity, separated by network")
    func derivation() throws {
        let words = try BIP39.mnemonic(entropy: testEntropy)
        let master = try HDKey(seed: BIP39.seed(mnemonic: words))
        let mnemonic = try LightningSeed.deriveV1(secret: .mnemonic(words), network: .regtest)
        let imported = try LightningSeed.deriveV1(secret: .masterKey(master.serialized()), network: .regtest)
        let otherNetwork = try LightningSeed.deriveV1(secret: .mnemonic(words), network: .mainnet)
        #expect(mnemonic.count == 32)
        #expect(mnemonic == imported)
        #expect(mnemonic != otherNetwork)
        #expect(mnemonic != master.privateKey)
        let standardWords = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let reference = try LightningSeed.deriveV1(secret: .mnemonic(standardWords), network: .regtest)
        // Independently calculated with PBKDF2-HMAC-SHA512, BIP32 master HMAC,
        // and HKDF-SHA256. Changing v1 must not silently rotate a live node.
        #expect(reference.hex == "34617f951070ca3872a663e852f466a722d068185e0e9e681f9a147aef35f96a")
    }
}
