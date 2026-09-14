import WalletCore
import Foundation

/// Why the opt-in explorer lookup could not answer. The message is what the
/// received-payment detail shows.
enum SenderLookupError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

/// The app's one direct explorer contact: resolving the funding addresses
/// of a received payment. Everywhere else the explorer is a warned link
/// opened in the browser.
///
/// Strictly single-shot and user-driven — one GET per explicit "Infer
/// sender" tap, made after the privacy warning, with no retries, no
/// caching, and no background caller. The explorer learns the device IP and
/// the exact transaction; the warning says so before this runs.
enum EsploraSenderLookup {
    /// GET {baseURL}/tx/{txid} and read each input's prevout address.
    static let maximumBytes = 2 * 1024 * 1024

    static func fundingAddresses(txid: Data, baseURL: URL, network: BitcoinNetwork,
                                 client: RoutedHTTPClient) async throws -> [String] {
        guard txid.count == 32 else { throw SenderLookupError.unavailable("Invalid transaction ID.") }
        let url = baseURL.appending(path: "tx").appending(path: txid.displayHex)
        let data = try await client.get(url, maximumBytes: maximumBytes)
        return try parseFundingAddresses(data: data, network: network, expectedTxid: txid.displayHex)
    }

    /// Strict Esplora `/tx` decoding, split from the fetch so tests feed it
    /// recorded answers: a top-level object with a `vin` array, each entry
    /// optionally carrying `prevout.scriptpubkey_address`. Returns the
    /// distinct addresses in input order; an input without one is skipped.
    /// Anything that is not this shape throws rather than guessing.
    static func parseFundingAddresses(data: Data, network: BitcoinNetwork = .mainnet, expectedTxid: String? = nil) throws -> [String] {
        guard data.count <= maximumBytes else { throw SenderLookupError.unavailable("Explorer response too large.") }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let vin = object["vin"] as? [[String: Any]], vin.count <= 10_000
        else {
            throw SenderLookupError.unavailable(
                "The explorer answered in a format Winnow does not understand.")
        }
        if let expectedTxid, object["txid"] as? String != expectedTxid {
            throw SenderLookupError.unavailable("The explorer returned a different transaction.")
        }
        var addresses: [String] = []
        for input in vin {
            guard let prevout = input["prevout"] as? [String: Any],
                  let address = prevout["scriptpubkey_address"] as? String,
                  !address.isEmpty, !addresses.contains(address)
            else { continue }
            _ = try AddressDecoder.scriptPubKey(for: address, network: network)
            addresses.append(address)
        }
        return addresses
    }
}
