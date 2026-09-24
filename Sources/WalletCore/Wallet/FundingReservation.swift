import Foundation

public enum FundingReservationError: Error, Equatable {
    case invalidRequest, requestChanged, unknownReservation, alreadySubmitted
    case inputsUnavailable, changeIndexExhausted, damagedRecord, storageUnavailable
}

/// Exact signed funding bytes retained while the channel protocol negotiates.
/// A reservation is not permission to broadcast. Submitted records cannot be
/// released merely because a peer disconnected or a request timed out.
public struct FundingReservation: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case reserved, submitted, broadcast }
    public let requestID: String
    public let amount: Int64
    public let scriptPubKey: Data
    public let feeRateSatPerVByte: Double
    public let rawTransaction: Data
    public let fee: Int64
    public internal(set) var phase: Phase
    let psbt: Data
    let selected: [WalletUTXO]
    let changeIndex: UInt32
    let changeOutputIndex: UInt32?

    public func transaction() throws -> Transaction { try Transaction.decode(rawTransaction) }

    func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128,
              amount > 0, amount <= BitcoinAmount.maximum,
              scriptPubKey.count == 34, scriptPubKey.prefix(2) == Data([0, 32]),
              feeRateSatPerVByte.isFinite, feeRateSatPerVByte > 0, feeRateSatPerVByte <= 10_000,
              fee >= 0, fee <= BitcoinAmount.maximum,
              !rawTransaction.isEmpty, rawTransaction.count <= 400_000,
              !psbt.isEmpty, psbt.count <= 4_000_000, !selected.isEmpty,
              changeIndex < HDKey.hardenedOffset else { throw FundingReservationError.damagedRecord }
        let tx = try transaction()
        guard tx.serialized(includeWitness: true) == rawTransaction,
              try PSBT(serialized: psbt).extractedTransaction() == tx,
              tx.inputs.map(\.previousOutput) == selected.map(\.outpoint),
              Set(selected.map(\.outpoint)).count == selected.count,
              tx.inputs.allSatisfy({ $0.scriptSig.isEmpty && !$0.witness.isEmpty }),
              tx.outputs.filter({ $0.value == amount && $0.scriptPubKey == scriptPubKey }).count == 1,
              tx.outputs.count == (changeOutputIndex == nil ? 1 : 2)
        else { throw FundingReservationError.damagedRecord }
        var inputTotal: Int64 = 0
        for coin in selected {
            guard coin.txid.count == 32, !coin.isSpent, !coin.scriptPubKey.isEmpty,
                  coin.amount > 0, coin.amount <= BitcoinAmount.maximum,
                  coin.amount <= BitcoinAmount.maximum - inputTotal else {
                throw FundingReservationError.damagedRecord
            }
            inputTotal += coin.amount
        }
        var outputTotal: Int64 = 0
        for output in tx.outputs {
            guard output.value > 0, output.value <= BitcoinAmount.maximum - outputTotal else {
                throw FundingReservationError.damagedRecord
            }
            outputTotal += output.value
        }
        guard inputTotal >= outputTotal, inputTotal - outputTotal == fee else {
            throw FundingReservationError.damagedRecord
        }
        if let index = changeOutputIndex {
            guard tx.outputs.indices.contains(Int(index)),
                  tx.outputs[Int(index)].scriptPubKey != scriptPubKey else {
                throw FundingReservationError.damagedRecord
            }
        }
    }
}
