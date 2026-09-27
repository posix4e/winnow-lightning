import Foundation

/// BOLT 1 warnings and errors share an encoding, but only errors are fatal.
/// Provider text is untrusted: never display control characters or unbounded data.
struct LightningPeerNotice: LocalizedError, CustomStringConvertible, Sendable {
    let channelID: Data
    let isError: Bool
    let detail: String

    init(_ message: LightningWire.Message) throws {
        guard [1, 17].contains(message.type) else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(message.payload)
        channelID = try reader.take(32)
        let bytes = try reader.take(Int(reader.u16()))
        isError = message.type == 17
        detail = bytes.allSatisfy { (32...126).contains($0) }
            ? String(decoding: bytes.prefix(240), as: UTF8.self) : ""
        // BOLT 1 permits ignoring trailing extensions to known messages.
    }

    var description: String {
        let prefix = isError ? "Provider error" : "Provider warning"
        return detail.isEmpty ? prefix : "\(prefix): \(detail)"
    }
    var errorDescription: String? { description }
}

extension LightningEngine {
    func recognizesNotice(_ notice: LightningPeerNotice, peer: Data) -> Bool {
        notice.channelID == Data(repeating: 0, count: 32) || state.channels.contains {
            $0.peer == peer && ($0.id == notice.channelID || $0.temporaryID == notice.channelID)
        }
    }
}
