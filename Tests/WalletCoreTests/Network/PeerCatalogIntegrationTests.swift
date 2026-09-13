import Foundation
import Testing
import TestSupport
@testable import WalletCore

private final class CatalogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CensusCatalogTests().now
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value += 8 * 86400 }
}

struct PeerCatalogIntegrationTests {
    @Test func refreshPreservesTheActiveConnectionAndResetPreservesCatalogAndManualPeers() async throws {
        let chain = makeSyntheticChain(length: 4, watchHeight: 2)
        let node = LoopbackNode(params: chain.params, chain: chain.blocks)
        try await node.start()
        let manual = await node.endpoint
        let pool = PeerPool(params: chain.params, peerCount: 1, manualPeers: [manual],
                            catalogNow: { CensusCatalogTests().now })
        await pool.start()
        let before = try #require(await pool.connectedPeers().first)
        try await pool.updateCensusCatalog(CensusCatalogTests().catalog())
        let after = try #require(await pool.connectedPeers().first)
        #expect(before === after)
        #expect(await before.isConnected)
        #expect(await pool.candidateSourcesForTest()[.init(host: "8.8.8.8", port: 8333)] == .fallback)
        #expect(await pool.candidateSourcesForTest()[.init(host: CensusCatalogTests().onion, port: 8333)] == nil)
        await pool.stop()
        try await pool.forgetKnownGood()
        let candidates = await pool.candidateSourcesForTest()
        #expect(candidates[manual] == .manual)
        #expect(candidates[.init(host: "8.8.8.8", port: 8333)] == .fallback)
        await node.stop()
    }

    @Test func expirationFallsBackToBundleAndFailedRefreshKeepsGoodCatalog() async throws {
        let clock = CatalogClock()
        let downloaded = CensusCatalogTests().catalog()
        let pool = PeerPool(params: .mainnet, censusCatalog: downloaded, catalogNow: { clock.read() })
        let peer = PeerEndpoint(host: "8.8.8.8", port: 8333)
        #expect(await pool.candidateEndpointsForTest() == [peer])
        var invalid = downloaded; invalid.schemaVersion = 2
        await #expect(throws: CensusCatalog.Invalid.schema) { try await pool.updateCensusCatalog(invalid) }
        #expect(await pool.candidateEndpointsForTest() == [peer])
        clock.advance()
        #expect(Set(await pool.candidateEndpointsForTest()) == Set(NetworkParams.mainnet.fallbackPeers))
    }

    @Test func torPrefersOnionsOverRememberedClearnetWithoutOverridingManualChoices() async throws {
        let fixture = CensusCatalogTests()
        let remembered = PeerEndpoint(host: "8.8.8.8", port: 8333)
        let manual = PeerEndpoint(host: "9.9.9.9", port: 8333)
        let file = FileManager.default.temporaryDirectory.appending(path: "peer-order-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(PersistedPeers([PeerCandidate(endpoint: remembered, source: .dnsSeed)]))
            .write(to: file)
        let pool = PeerPool(params: .mainnet, manualPeers: [manual], peersFileURL: file,
                            route: .tor(proxy: .init(host: "127.0.0.1", port: 9050)),
                            censusCatalog: fixture.catalog(), catalogNow: { fixture.now })
        let candidates = await pool.candidateEndpointsForTest()
        #expect(candidates == [manual, .init(host: fixture.onion, port: 8333), remembered])
        let sources = await pool.candidateSourcesForTest()
        #expect(sources[remembered] == .dnsSeed, "transport preference must preserve source diversity")
        #expect(sources[manual] == .manual)
    }

    @Test func reshuffleAvoidsPreviousPeersAndOnionsRequireTor() async {
        let fixture = CensusCatalogTests()
        var catalog = fixture.catalog()
        catalog.networks["clearnet"]!.append(.init(host: "9.9.9.9", port: 8333, userAgent: "", startHeight: 900_000))
        let previous = PeerEndpoint(host: "8.8.8.8", port: 8333)
        let pool = PeerPool(params: .mainnet, censusCatalog: catalog, catalogNow: { fixture.now }, avoidOnReset: [previous])
        #expect(await pool.candidateEndpointsForTest().first == .init(host: "9.9.9.9", port: 8333))
        let tor = PeerPool(params: .mainnet, route: .tor(proxy: .init(host: "127.0.0.1", port: 9050)),
                           censusCatalog: catalog, catalogNow: { fixture.now })
        let candidates = await tor.candidateEndpointsForTest()
        #expect(candidates.first?.host == fixture.onion)
        #expect(!candidates.contains { $0.overlay == .i2p })
        let sources = await tor.candidateSourcesForTest()
        #expect(Set(sources.values) == [.fallback], "bundled and refreshed census peers are one trust source")
    }
}
