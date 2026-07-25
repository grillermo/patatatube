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
    private var manifest: CapturedDownloadManifest?

    init(
        cacheKey: String,
        remoteURL: URL,
        bearerToken: String?,
        videoId: Int,
        versionId: Int?,
        store: CapturedDownloadStore,
        session: URLSession,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.cacheKey = cacheKey
        self.remoteURL = remoteURL
        self.bearerToken = bearerToken
        self.videoId = videoId
        self.versionId = versionId
        self.store = store
        self.session = session
        self.onProgress = onProgress
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

        // Resume an existing partial only if the entity is unchanged.
        var loaded = try? store.load(cacheKey: cacheKey)
        if let existing = loaded, existing.etag != etag {
            store.remove(cacheKey: cacheKey)
            loaded = nil
        }
        let m = loaded ?? CapturedDownloadManifest.make(
            videoId: videoId, versionId: versionId, remoteURL: remoteURL,
            totalByteCount: total, etag: etag)
        try store.ensureSparseFile(cacheKey: cacheKey, totalByteCount: total)
        try store.write(m)
        manifest = m
        onProgress(CapturedRanges.coveredBytes(m.capturedRanges), m.totalByteCount)
        return ContentInfo(totalByteCount: total, etag: etag)
    }

    func data(for range: DownloadByteRange) async throws -> Data {
        guard let m = manifest else {
            _ = try await loadContentInfo()
            return try await data(for: range)
        }
        // Fully captured already → serve from disk.
        if CapturedRanges.complement(of: m.capturedRanges, over: m.totalByteCount)
            .allSatisfy({ $0.end < range.start || $0.start > range.end }) {
            return try store.readRange(cacheKey: cacheKey, range: range)
        }
        // Fetch the requested range from the network (simple whole-range fetch;
        // overlaps with existing captured bytes are harmless — same content).
        let (data, response) = try await session.data(for: authedRequest(range: range.headerValue))
        guard let http = response as? HTTPURLResponse else { throw RangeFetcherError.invalidProbe }
        if (400..<600).contains(http.statusCode) { throw RangeFetcherError.badStatus(http.statusCode) }
        guard http.statusCode == 206 else { throw RangeFetcherError.invalidProbe }
        guard http.value(forHTTPHeaderField: "ETag") == m.etag else { throw RangeFetcherError.changedEntity }
        guard Int64(data.count) == range.length else { throw RangeFetcherError.lengthMismatch }

        try store.writeRange(cacheKey: cacheKey, offset: range.start, data: data)
        // Re-read after the await: this actor is reentrant, so another caller may
        // have captured ranges while this fetch was in flight. Mutating the
        // pre-await snapshot would silently drop their work.
        guard var current = manifest else { return data }
        current.capture(range)
        try store.write(current)
        manifest = current
        onProgress(CapturedRanges.coveredBytes(current.capturedRanges), current.totalByteCount)
        return data
    }

    /// Fetch every uncaptured range, then publish the completed file. Leaves the
    /// partial intact and rethrows on any failure (never publishes a partial).
    func finalize(destination: URL) async throws {
        guard let m0 = manifest else { _ = try await loadContentInfo(); return try await finalize(destination: destination) }
        let chunk: Int64 = 4 * 1_048_576
        for gap in CapturedRanges.complement(of: m0.capturedRanges, over: m0.totalByteCount) {
            var start = gap.start
            while start <= gap.end {
                let end = min(start + chunk - 1, gap.end)
                _ = try await data(for: DownloadByteRange(start: start, end: end))
                start = end + 1
            }
        }
        guard let m = manifest, m.isComplete else { throw RangeFetcherError.lengthMismatch }
        try store.publish(cacheKey: cacheKey, to: destination)
        manifest = nil
    }
}

/// Strong ETag: quoted, not weak (`W/`-prefixed).
private func isStrongETag(_ value: String) -> Bool {
    value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
}
