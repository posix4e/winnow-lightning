import Foundation
import libsecp256k1
import P256K

extension Bolt11Invoice {
    /// P256K's public recovery initializer traps on failed recovery. Invoices
    /// are untrusted: use the same pinned library's fallible C primitive.
    static func recover(signature: Data, digest: Data) throws -> Data {
        guard signature.count == 65, digest.count == 32, signature.last! <= 3 else { throw LightningError.invalidSignature }
        let context = P256K.Context.rawRepresentation
        var recoverable = secp256k1_ecdsa_recoverable_signature(), publicKey = secp256k1_pubkey()
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(context, &recoverable,
            Array(signature.prefix(64)), Int32(signature.last!)) == 1,
              secp256k1_ecdsa_recover(context, &publicKey, &recoverable, Array(digest)) == 1
        else { throw LightningError.invalidSignature }
        var bytes = [UInt8](repeating: 0, count: 33), length = 33
        guard secp256k1_ec_pubkey_serialize(context, &bytes, &length, &publicKey, UInt32(SECP256K1_EC_COMPRESSED)) == 1
        else { throw LightningError.invalidSignature }
        return Data(bytes)
    }
}
