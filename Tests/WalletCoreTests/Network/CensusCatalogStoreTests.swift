import Foundation
import Testing
@testable import WalletCore

struct CensusCatalogStoreTests {
    @Test func replacementRecoveryAndExpiration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CensusCatalogStore(url: directory.appendingPathComponent("catalog.json"))
        let fixture = CensusCatalogTests()
        let original = try JSONEncoder().encode(fixture.catalog())
        let download = try store.replace(with: original, now: fixture.now)
        #expect(download.sha256.count == 64)
        #expect(store.load(now: fixture.now)?.sha256 == download.sha256)
        #expect(throws: (any Error).self) { try store.replace(with: Data("{}".utf8), now: fixture.now) }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(store.load(now: fixture.now.addingTimeInterval(8 * 86400)) == nil)
        #expect(try Data(contentsOf: store.url) == original)
        #expect(throws: (any Error).self) {
            try store.replace(with: Data(repeating: 0, count: CensusCatalog.maximumBytes + 1), now: fixture.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
    }
}
