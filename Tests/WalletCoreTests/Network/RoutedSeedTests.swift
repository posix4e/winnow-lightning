import Foundation
import os
import Testing
import TestSupport
@testable import WalletCore

struct RoutedSeedTests {
    @Test func dnsJSONContentNegotiationTravelsThroughProxy() async throws {
        let body = Data(#"{"Status":0,"Answer":[{"type":1,"data":"8.8.8.8"}]}"#.utf8)
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponse: reply)
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = SeedResolver.routed(client: client, endpoint: URL(string: "http://resolver.invalid/dns-query")!,
                                           systemResolve: { _, _ in calls.withLock { $0 += 1 }; return [] })
        let endpoints = await resolver.resolve(host: "seed.invalid", port: 8333, allowPrivate: false)
        #expect(endpoints == [.init(host: "8.8.8.8", port: 8333)])
        #expect(calls.withLock { $0 } == 0)
        let requests = await proxy.httpRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.lowercased().contains("accept: application/dns-json\r\n") })
        #expect(await proxy.requestedHosts == ["resolver.invalid", "resolver.invalid"])
        client.cancel(); await proxy.stop()
    }

    @Test func refusedTorDNSNeverInvokesSystemResolver() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 4)
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = SeedResolver.routed(client: client, endpoint: URL(string: "http://resolver.invalid/dns-query")!,
                                           systemResolve: { _, _ in
                                               calls.withLock { $0 += 1 }
                                               return [.init(host: "8.8.8.8", port: 8333)]
                                           })
        #expect(await resolver.resolve(host: "seed.invalid", port: 8333, allowPrivate: false).isEmpty)
        #expect(calls.withLock { $0 } == 0)
        #expect(await proxy.requestedHosts.count == 2)
        client.cancel(); await proxy.stop()
    }
}
