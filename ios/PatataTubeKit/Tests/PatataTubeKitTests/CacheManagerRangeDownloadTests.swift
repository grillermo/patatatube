import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager range download", .serialized)
struct CacheManagerRangeDownloadTests {
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-range-\(UUID().uuidString)")
    }

    private func installHandler() {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    private func makeManager(root: URL) -> CacheManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CacheManager(root: root, configuration: config)
    }

    @Test func downloadWritesCompleteFileAndReportsCached() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 4)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
        #expect(manager.recentDownloads().contains { $0.videoID == 1 })
    }

    @Test func downloadResumesFromBytesLeftByPlayback() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        // Watch-capture the first half through the public capture path.
        let asset = manager.captureAsset(
            videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 49), origin: .player)
        #expect(manager.state(for: 1) == .downloading(0.5))

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }

    /// Regression for the progress-freeze bug: `registerCaptureProgress` used to
    /// suppress every `inFlight` update fired by a `download()`'s own fetcher
    /// (guarded by `downloadTasks[key] != nil`, which `download()` itself sets
    /// before the fetcher starts emitting). That left `state(for:)` frozen at
    /// whatever progress existed when the download started, for the whole
    /// transfer. Pre-captures the middle third out-of-band (progress 0.2), then
    /// starts a two-worker download whose second chunk is gated so the test can
    /// observe progress having moved to 0.6 (the first chunk landing) while the
    /// download is still in flight — proving `inFlight` updates live instead of
    /// staying pinned at 0.2 until completion.
    @Test func downloadReportsLiveIntermediateProgressNotFrozen() async throws {
        let body = body
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            // Hold back the second gap chunk (60-99) until the test signals,
            // giving a deterministic window to observe the first chunk's
            // progress update while the download is still running.
            if start == 60 { gate.wait() }
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
        let root = root()
        let manager = makeManager(root: root)
        // Pre-capture the middle third (40-59) out-of-band, leaving two gaps:
        // 0-39 and 60-99. Progress is 20/100 = 0.2 before download() starts.
        _ = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 40, end: 59), origin: .player)
        #expect(manager.state(for: 1) == .downloading(0.2))

        let download = Task {
            try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)
        }

        // The 0-39 chunk completes immediately; the 60-99 chunk is held by the
        // gate. Poll for progress to move past the pre-capture's 0.2 while the
        // download is still in flight (the file must not be cached yet).
        var observedIntermediate = false
        for _ in 0..<200 {
            if manager.state(for: 1) == .downloading(0.6) {
                observedIntermediate = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(observedIntermediate)
        // Still mid-transfer: the second chunk hasn't been released yet.
        #expect(manager.state(for: 1) != .cached)

        gate.signal()
        try await download.value

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }

    /// Regression for the leaked-bookkeeping bug: `resumeInterrupted`'s spawned
    /// `Task` was truly fire-and-forget — nothing awaited it or cleaned up after
    /// it, unlike `download()`. On success this meant the resumed video never
    /// showed up in `recentDownloads()` and `downloadTasks`/`inFlight` stayed
    /// populated forever. Seeds a capture manifest directly on disk (as if the
    /// app was killed mid-capture), resumes it, waits for completion, then
    /// checks the same bookkeeping `download()` clears: history recorded and
    /// both maps released.
    @Test func resumeInterruptedCleansUpAndRecordsHistoryOnSuccess() async throws {
        installHandler()
        let root = root()
        let store = CapturedDownloadStore(root: root)
        let manifest = CapturedDownloadManifest.make(
            videoId: 5, versionId: nil, remoteURL: remote,
            totalByteCount: Int64(body.count), etag: "\"v1\"")
        try store.write(manifest)
        let manager = makeManager(root: root)

        #expect(manager.resumeInterrupted(bearerToken: "t") == [5])

        for _ in 0..<500 where manager.state(for: 5) != .cached {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(manager.state(for: 5) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 5)) == body)
        #expect(manager.recentDownloads().contains { $0.videoID == 5 })
        #expect(manager.activeDownloads().isEmpty)
        #expect(!manager.hasDownloadTask(videoId: 5, versionId: nil))
    }

    @Test func cancelKeepsPartialAndReportsPaused() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)

        manager.cancel(id: 1)

        #expect(manager.state(for: 1) == .paused(0.4))
        let partial = CapturedDownloadStore(root: root).partURL(cacheKey: "1")
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func resumeAfterCancelCompletesFromGaps() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)
        manager.cancel(id: 1)

        try await manager.download(id: 1, from: remote, bearerToken: "t", streamCount: 2)

        #expect(manager.state(for: 1) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 1)) == body)
    }

    @Test func removePartialClearsPausedState() async throws {
        installHandler()
        let root = root()
        let manager = makeManager(root: root)
        let asset = manager.captureAsset(videoId: 1, remoteURL: remote, bearerToken: "t")
        #expect(asset.url.scheme == CaptureManager.scheme)
        let fetcher = try #require(manager.testFetcher(videoId: 1, versionId: nil))
        _ = try await fetcher.data(for: .init(start: 0, end: 39), origin: .player)
        manager.cancel(id: 1)

        manager.removePartial(id: 1)

        #expect(manager.state(for: 1) == .notCached)
        let partial = CapturedDownloadStore(root: root).partURL(cacheKey: "1")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}
