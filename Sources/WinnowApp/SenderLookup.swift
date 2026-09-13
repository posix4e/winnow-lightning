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
    static func fundingAddresses(txid: Data, baseURL: URL) async throws -> [String] {
        let url = baseURL.appending(path: "tx").appending(path: txid.displayHex)
        // Single-shot: a fresh answer every tap, never the shared cache.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SenderLookupError.unavailable(
                "The explorer could not be reached. Check the network connection and try again.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SenderLookupError.unavailable("The explorer's answer was not HTTP.")
        }
        guard http.statusCode == 200 else {
            throw SenderLookupError.unavailable(
                http.statusCode == 404
                    ? "The explorer has not seen this transaction."
                    : "The explorer answered with an error (HTTP \(http.statusCode)).")
        }
        return try parseFundingAddresses(data: data)
    }

    /// Strict Esplora `/tx` decoding, split from the fetch so tests feed it
    /// recorded answers: a top-level object with a `vin` array, each entry
    /// optionally carrying `prevout.scriptpubkey_address`. Returns the
    /// distinct addresses in input order; an input without one is skipped.
    /// Anything that is not this shape throws rather than guessing.
    static func parseFundingAddresses(data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let vin = object["vin"] as? [[String: Any]]
        else {
            throw SenderLookupError.unavailable(
                "The explorer answered in a format Winnow does not understand.")
        }
        var addresses: [String] = []
        for input in vin {
            guard let prevout = input["prevout"] as? [String: Any],
                  let address = prevout["scriptpubkey_address"] as? String,
                  !address.isEmpty, !addresses.contains(address)
            else { continue }
            addresses.append(address)
        }
        return addresses
    }
}
