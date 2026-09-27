import Foundation
import XCTest
@testable import LightningCore

final class RoutingGraphTests: XCTestCase {
    private let chain = Data(repeating: 7, count: 32)
    private func key(_ n: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: n, count: 32)) }
    private func signed(_ payload: Data, seeds: [UInt8]) throws -> Data {
        let hash = ChannelKeys.hash(ChannelKeys.hash(payload))
        return try seeds.reduce(Data()) { try $0 + ChannelKeys.compactSignature(ChannelKeys.sign(digest: hash, secret: Data(repeating: $1, count: 32))) } + payload
    }
    private func announcement(_ id: UInt64, a: UInt8, b: UInt8, chain: Data? = nil) throws -> LightningWire.Message {
        let nodes = try [a, b].sorted { try key($0).lexicographicallyPrecedes(key($1)) }
        var w = LightningWire.Writer(); w.u16(0); w.append(chain ?? self.chain); w.u64(id)
        for seed in nodes + [11, 12] { w.append(try key(seed)) }
        return try .init(type: 256, payload: signed(w.data, seeds: nodes + [11, 12]))
    }
    private func policy(_ id: UInt64, a: UInt8, b: UInt8, timestamp: UInt32, fee: UInt32 = 1000, disabled: Bool = false) throws -> LightningWire.Message {
        var w = LightningWire.Writer(); w.append(chain); w.u64(id); w.u32(timestamp); w.u8(1)
        w.u8((try key(a).lexicographicallyPrecedes(key(b)) ? 0 : 1) | (disabled ? 2 : 0))
        w.u16(40); w.u64(1000); w.u32(fee); w.u32(0); w.u64(10_000_000)
        return try .init(type: 258, payload: signed(w.data, seeds: [a]))
    }
    func testAllAnnouncementSignaturesAndPolicyDirectionAreValidated() throws {
        var graph = LightningRoutingGraph(chain: chain)
        let valid = try announcement(123, a: 1, b: 2)
        for index in [0, 64, 128, 192] {
            var corrupt = valid.payload; corrupt[index] ^= 1
            try graph.receive(.init(type: 256, payload: corrupt), now: 100)
            XCTAssertTrue(graph.channels.isEmpty)
        }
        try graph.receive(announcement(123, a: 1, b: 2, chain: Data(repeating: 8, count: 32)), now: 100)
        XCTAssertTrue(graph.channels.isEmpty)
        try graph.receive(valid, now: 100)
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 100), now: 100)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.hop.peer, try key(1))
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 99, fee: 9000), now: 100)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.hop.baseMsat, 1000)
        var corrupt = try policy(123, a: 1, b: 2, timestamp: 101).payload; corrupt[0] ^= 1
        try graph.receive(.init(type: 258, payload: corrupt), now: 101)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.timestamp, 100)
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 101, disabled: true), now: 101)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.disabled, true)
    }
    func testReverseSearchHonorsFeesAndDisabledEdges() throws {
        var graph = LightningRoutingGraph(chain: chain)
        for (id, a, b, fee) in [(UInt64(123), UInt8(1), UInt8(3), UInt32(3000)), (456, 1, 2, 1000), (789, 2, 3, 500)] {
            try graph.receive(announcement(id, a: a, b: b), now: 100)
            try graph.receive(policy(id, a: a, b: b, timestamp: 100, fee: fee), now: 100)
        }
        let invoice = Bolt11Invoice.Decoded(amountMsat: 5000, paymentHash: Data(repeating: 1, count: 32), paymentSecret: Data(repeating: 2, count: 32),
            payee: try key(3), timestamp: 100, expirySeconds: 3600, description: nil, descriptionHash: nil, metadata: nil,
            minimumFinalDelta: 18, features: .init(bytes: Data()), routes: [])
        let cheapest = try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 3000, maximumDelta: 144)
        XCTAssertEqual(cheapest.hops.map(\.shortChannelID), [456, 789])
        try graph.receive(policy(456, a: 1, b: 2, timestamp: 101, fee: 1000, disabled: true), now: 101)
        XCTAssertEqual(try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 3000, maximumDelta: 144).hops.map(\.shortChannelID), [123])
        XCTAssertThrowsError(try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 2999, maximumDelta: 144))
        XCTAssertThrowsError(try graph.route(from: key(1), invoice: invoice, amountMsat: 500, feeLimitMsat: 3000, maximumDelta: 144))
    }
}
