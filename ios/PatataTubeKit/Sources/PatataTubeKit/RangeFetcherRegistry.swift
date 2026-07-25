import Foundation

/// One `RangeFetcher` per video, shared by playback capture and explicit
/// download. Both paths must reach the *same* actor for a cache key — that is
/// what makes their bytes visible to each other.
final class RangeFetcherRegistry: @unchecked Sendable {
    private let store: CapturedDownloadStore
    private let session: URLSession
    private let waitBeforePublication: @Sendable () async -> Void
    private let lock = NSLock()
    private var fetchers: [String: (fetcher: RangeFetcher, lifetime: RangeFetcherLifetime)] = [:]

    init(
        store: CapturedDownloadStore,
        session: URLSession,
        waitBeforePublication: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.session = session
        self.waitBeforePublication = waitBeforePublication
    }

    static func cacheKey(videoId: Int, versionId: Int?) -> String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    /// Existing fetcher for the key, or a new one. `onProgress` is used only
    /// when creating — an existing fetcher keeps the callback it was built with,
    /// which is already wired to the same `CacheManager`.
    func fetcher(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        bearerToken: String?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) -> RangeFetcher {
        let key = Self.cacheKey(videoId: videoId, versionId: versionId)
        return lock.withLock {
            if let existing = fetchers[key] { return existing.fetcher }
            let lifetime = RangeFetcherLifetime()
            let fetcher = RangeFetcher(
                cacheKey: key, remoteURL: remoteURL, bearerToken: bearerToken,
                videoId: videoId, versionId: versionId,
                store: store, session: session, onProgress: onProgress,
                lifetime: lifetime, waitBeforePublication: waitBeforePublication)
            fetchers[key] = (fetcher, lifetime)
            return fetcher
        }
    }

    func existing(cacheKey: String) -> RangeFetcher? {
        lock.withLock { fetchers[cacheKey]?.fetcher }
    }

    func remove(cacheKey: String) {
        let lifetime = lock.withLock {
            fetchers.removeValue(forKey: cacheKey)?.lifetime
        }
        lifetime?.invalidate()
    }

    func cancelPublication(cacheKey: String) {
        let lifetime = lock.withLock { fetchers[cacheKey]?.lifetime }
        lifetime?.cancelPublicationAttempt()
    }
}
