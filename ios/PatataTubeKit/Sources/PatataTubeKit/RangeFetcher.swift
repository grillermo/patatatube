import Foundation

struct ContentInfo: Equatable, Sendable {
    let totalByteCount: Int64
    let etag: String
}

enum RangeFetcherError: Error, Equatable {
    case invalidProbe
    case changedEntity
    case badStatus(Int)
    case lengthMismatch
}

/// Who asked for a range. Player requests are latency-sensitive and throttle
/// any concurrent background download of the same video.
enum FetchOrigin: Sendable {
    case player
    case downloader
}

/// Coordinates an actor's file mutations with registry eviction. Eviction waits
/// for any current mutation, then permanently rejects every later mutation from
/// the retired actor so a deleted partial cannot reappear after a URL request
/// resumes.
final class RangeFetcherLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var invalidated = false
    private var mutationCount = 0

    func invalidate() {
        condition.lock()
        invalidated = true
        while mutationCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func performMutation<T>(_ mutation: () throws -> T) throws -> T {
        condition.lock()
        guard !invalidated else {
            condition.unlock()
            throw CancellationError()
        }
        mutationCount += 1
        condition.unlock()

        let result = Result { try mutation() }

        condition.lock()
        mutationCount -= 1
        let wasInvalidated = invalidated
        condition.broadcast()
        condition.unlock()

        if wasInvalidated { throw CancellationError() }
        return try result.get()
    }
}

/// Serves inclusive byte ranges of a remote MP4, capturing every fetched byte
/// to a sparse file tracked by a `CapturedDownloadManifest`. One instance per
/// playing video; serialized via `actor`.
actor RangeFetcher {
    let cacheKey: String
    let remoteURL: URL
    let bearerToken: String?
    let videoId: Int
    let versionId: Int?
    private let store: CapturedDownloadStore
    private let session: URLSession
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lifetime: RangeFetcherLifetime
    private var manifest: CapturedDownloadManifest?
    /// When the resource loader last asked for bytes. Drives back-pressure on a
    /// concurrent background download of the same video.
    private var lastPlayerRequestAt: Date?
    private let now: @Sendable () -> Date

    /// Gap-fill request size. Also the maximum work lost when the app is
    /// suspended mid-transfer.
    static let chunkSize: Int64 = 4 * 1_048_576

    init(
        cacheKey: String,
        remoteURL: URL,
        bearerToken: String?,
        videoId: Int,
        versionId: Int?,
        store: CapturedDownloadStore,
        session: URLSession,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        lifetime: RangeFetcherLifetime = RangeFetcherLifetime()
    ) {
        self.cacheKey = cacheKey
        self.remoteURL = remoteURL
        self.bearerToken = bearerToken
        self.videoId = videoId
        self.versionId = versionId
        self.store = store
        self.session = session
        self.onProgress = onProgress
        self.now = now
        self.lifetime = lifetime
    }

    var manifestSnapshot: CapturedDownloadManifest? { manifest }

    private func authedRequest(range: String) -> URLRequest {
        var request = URLRequest(url: remoteURL)
        request.setValue(range, forHTTPHeaderField: "Range")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func loadContentInfo() async throws -> ContentInfo {
        if let manifest { return ContentInfo(totalByteCount: manifest.totalByteCount, etag: manifest.etag) }

        let (data, response) = try await session.data(for: authedRequest(range: "bytes=0-0"))
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              let etag = http.value(forHTTPHeaderField: "ETag"), isStrongETag(etag),
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0, data.count == 1
        else { throw RangeFetcherError.invalidProbe }

        let m = try lifetime.performMutation {
            // Resume an existing partial only if the entity is unchanged.
            var loaded = try? store.load(cacheKey: cacheKey)
            if let existing = loaded, existing.etag != etag {
                store.remove(cacheKey: cacheKey)
                loaded = nil
            }
            let manifest = loaded ?? CapturedDownloadManifest.make(
                videoId: videoId, versionId: versionId, remoteURL: remoteURL,
                totalByteCount: total, etag: etag)
            try store.ensureSparseFile(cacheKey: cacheKey, totalByteCount: total)
            try store.write(manifest)
            onProgress(
                CapturedRanges.coveredBytes(manifest.capturedRanges),
                manifest.totalByteCount)
            return manifest
        }
        manifest = m
        return ContentInfo(totalByteCount: total, etag: etag)
    }

    func data(for range: DownloadByteRange, origin: FetchOrigin = .downloader) async throws -> Data {
        if origin == .player { lastPlayerRequestAt = now() }
        guard let m = manifest else {
            _ = try await loadContentInfo()
            return try await data(for: range)
        }
        // Fully captured already → serve from disk.
        if CapturedRanges.complement(of: m.capturedRanges, over: m.totalByteCount)
            .allSatisfy({ $0.end < range.start || $0.start > range.end }) {
            return try lifetime.performMutation {
                try store.readRange(cacheKey: cacheKey, range: range)
            }
        }
        // Fetch the requested range from the network (simple whole-range fetch;
        // overlaps with existing captured bytes are harmless — same content).
        let (data, response) = try await session.data(for: authedRequest(range: range.headerValue))
        guard let http = response as? HTTPURLResponse else { throw RangeFetcherError.invalidProbe }
        if (400..<600).contains(http.statusCode) { throw RangeFetcherError.badStatus(http.statusCode) }
        guard http.statusCode == 206 else { throw RangeFetcherError.invalidProbe }
        guard http.value(forHTTPHeaderField: "ETag") == m.etag else { throw RangeFetcherError.changedEntity }
        guard Int64(data.count) == range.length else { throw RangeFetcherError.lengthMismatch }

        // Re-read after the await: this actor is reentrant, so another caller may
        // have captured ranges while this fetch was in flight. Mutating the
        // pre-await snapshot would silently drop their work.
        guard var current = manifest else { return data }
        try Task.checkCancellation()
        try lifetime.performMutation {
            try store.writeRange(cacheKey: cacheKey, offset: range.start, data: data)
            current.capture(range)
            try store.write(current)
            onProgress(
                CapturedRanges.coveredBytes(current.capturedRanges),
                current.totalByteCount)
        }
        manifest = current
        return data
    }

    /// A background download yields to a live playhead: while the resource
    /// loader has asked for bytes within this window, only one worker runs.
    static let playbackBackPressureWindow: TimeInterval = 10

    static func effectiveConcurrency(
        requested: Int, lastPlayerRequestAt: Date?, now: Date
    ) -> Int {
        let clamped = min(max(requested, 1), 4)
        guard let lastPlayerRequestAt,
              now.timeIntervalSince(lastPlayerRequestAt) < playbackBackPressureWindow
        else { return clamped }
        return 1
    }

    /// Fetches every uncaptured byte using `concurrency` parallel workers,
    /// ascending by offset so the file head (and its faststart `moov`) lands
    /// first and playback can start off disk immediately.
    func fetchAll(concurrency: Int) async throws {
        let info = try await loadContentInfo()
        func workerBudget() -> Int {
            Self.effectiveConcurrency(
                requested: concurrency, lastPlayerRequestAt: lastPlayerRequestAt, now: now())
        }
        var chunks: [DownloadByteRange] = []
        for gap in CapturedRanges.complement(
            of: manifest?.capturedRanges ?? [], over: info.totalByteCount
        ) {
            var start = gap.start
            while start <= gap.end {
                let end = min(start + Self.chunkSize - 1, gap.end)
                chunks.append(DownloadByteRange(start: start, end: end))
                start = end + 1
            }
        }
        guard !chunks.isEmpty else { return }

        var next = 0
        var runningCount = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            func addNext() {
                guard next < chunks.count else { return }
                let range = chunks[next]
                next += 1
                runningCount += 1
                group.addTask { _ = try await self.data(for: range) }
            }
            for _ in 0..<min(workerBudget(), chunks.count) { addNext() }
            while try await group.next() != nil {
                runningCount -= 1
                try Task.checkCancellation()
                // One completion frees one slot; only refill up to the live budget,
                // so a worker pool actually shrinks when playback starts mid-download
                // instead of staying pinned at whatever count fetchAll started with.
                while runningCount < workerBudget() && next < chunks.count { addNext() }
            }
        }
    }

    /// `fetchAll` plus publication into the cache. Leaves the partial intact and
    /// rethrows on any failure (never publishes a partial).
    func downloadAll(concurrency: Int, destination: URL) async throws {
        try await fetchAll(concurrency: concurrency)
        try Task.checkCancellation()
        guard let m = manifest, m.isComplete else { throw RangeFetcherError.lengthMismatch }
        try lifetime.performMutation {
            try store.publish(cacheKey: cacheKey, to: destination)
        }
        manifest = nil
    }

    /// Watch-to-cache finalisation: single-worker completion of a partial.
    func finalize(destination: URL) async throws {
        try await downloadAll(concurrency: 1, destination: destination)
    }
}

/// Strong ETag: quoted, not weak (`W/`-prefixed).
private func isStrongETag(_ value: String) -> Bool {
    value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
}
