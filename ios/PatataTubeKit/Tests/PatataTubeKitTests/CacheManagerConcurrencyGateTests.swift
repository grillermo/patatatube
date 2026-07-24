import Foundation
import Testing
@testable import PatataTubeKit

private final class SpyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var limit = 3

    func acquire() async { lock.withLock { acquireCount += 1 } }
    func release() { lock.withLock { releaseCount += 1 } }
    func setLimit(_ n: Int) { lock.withLock { limit = max(n, 1) } }
    var currentLimit: Int { lock.withLock { limit } }
}

// Nested inside APIClientTests (declared in APIClientReadTests.swift) so it inherits that
// suite's `.serialized` trait — MockURLProtocol.handler is a global static shared by every
// test that sets it, and a sibling top-level suite would otherwise run concurrently with it
// and race on the handler (observed as intermittent APIClientLibraryTests failures).
extension APIClientTests {
struct CacheManagerConcurrencyGateTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-cache-\(UUID().uuidString)")
    }

    @Test
    func downloadAcquiresAndReleasesEvenOnFailure() async {
        let spy = SpyGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { MockURLProtocol.handler = nil }

        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: config,
            fileManager: .default,
            concurrencyGate: spy
        )

        // The download fails (probe errors out), but the slot must be released.
        try? await manager.download(
            id: 1,
            from: URL(string: "https://example.com/v.mp4")!
        )

        #expect(spy.acquireCount == 1)
        #expect(spy.releaseCount == 1)
    }

    @Test
    func setMaxConcurrentDownloadsForwardsToGate() {
        let spy = SpyGate()
        let manager = CacheManager(
            root: temporaryRoot(),
            configuration: .ephemeral,
            fileManager: .default,
            concurrencyGate: spy
        )
        manager.setMaxConcurrentDownloads(2)
        #expect(spy.currentLimit == 2)
        #expect(manager.maxConcurrentDownloads == 2)
    }
}
}
