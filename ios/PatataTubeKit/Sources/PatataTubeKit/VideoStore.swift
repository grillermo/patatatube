import Foundation
import Combine

public enum PrepareError: Error, Equatable {
    case conversionFailed(String)
}

/// The one thing VideoStore needs from CacheManager: dropping a video's
/// downloaded files once the server says the video is gone.
public protocol MediaCaching: Sendable {
    func removeAllCached(id: Int)
}

@MainActor
public final class VideoStore: ObservableObject {
    @Published public private(set) var videos: [Video] = []
    @Published public var filter: String? {
        didSet { defaults.set(filter, forKey: Self.filterKey) }
    }
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI
    private let cache: VideoListCaching?
    private let mediaCache: MediaCaching?
    private let positionStore: ResumePositionStore?
    private let defaults: UserDefaults
    private static let filterKey = "selectedClassification"

    /// Bumped by every switchFilter()/load() invocation so a stale, still-in-flight
    /// call can tell it's been superseded and must not clobber `videos`/`isLoading`
    /// with results that no longer match the current tab/request.
    private var loadGeneration = 0

    public init(api: VideoAPI, cache: VideoListCaching? = nil,
                mediaCache: MediaCaching? = nil,
                positionStore: ResumePositionStore? = nil,
                defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.mediaCache = mediaCache
        self.positionStore = positionStore
        self.defaults = defaults
        self.filter = defaults.string(forKey: Self.filterKey) ?? "children"
    }

    /// Reads + JSON-decodes the persisted list off the main actor. Done inline it
    /// blocked the main thread at startup long enough to trip Sentry's app-hang
    /// detector (PATATATUBE-3, NSFileHandle.read during first render).
    private func loadCache() async -> [Video]? {
        guard let cache else { return nil }
        let classification = filter
        return await Task.detached(priority: .utility) {
            cache.load(classification: classification)
        }.value
    }

    /// Boot path: show cached videos instantly if present, then refresh from network.
    /// With no cache, falls back to a plain network load.
    public func bootLoad() async {
        if let cached = await loadCache(), !cached.isEmpty {
            videos = cached
        }
        await load()
    }

    /// Tab-switch path: swap to the new classification's cached list instantly
    /// (or an empty list, which the grid renders as skeletons), then refresh
    /// from the network. Mirrors bootLoad()'s cache-first behavior so switching
    /// tabs never lingers on the previous classification's videos.
    ///
    /// `filter`, `videos`, and `isLoading` are all updated synchronously, in that
    /// order, before the first `await`. This closes the MainActor-visible window
    /// where `filter` already reflects the new tab but `videos`/`isLoading` still
    /// reflect the old one -- `loadCache()` hops to a background thread internally,
    /// so any state left stale going into that suspension could otherwise render.
    ///
    /// `loadGeneration` guards against a second, faster tab switch landing while
    /// this one is still awaiting its cache read or network fetch: each call
    /// captures its own generation and only applies what it fetches if no newer
    /// switchFilter()/load() call has started in the meantime.
    public func switchFilter(to value: String?) async {
        loadGeneration += 1
        let generation = loadGeneration
        filter = value
        videos = []
        isLoading = true
        let cached = await loadCache()
        guard generation == loadGeneration else { return }   // superseded meanwhile
        if let cached { videos = cached }
        await load()
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let positionSnapshot = positionStore?.freshServerReconciliationSnapshot()
        isLoading = true
        errorText = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await api.videos(classification: filter)
            // Encode + atomic disk write off the main actor: doing it inline here
            // (this method is @MainActor) blocked the main thread long enough to
            // trip Sentry's app-hang detector (PATATATUBE-2, NSFileHandle.write).
            if let cache {
                let toSave = fetched
                let classification = filter
                // await the detached task's value: the main actor suspends (freeing
                // the main thread to render) while the encode + write runs on a
                // background thread, then resumes. Not fire-and-forget, so callers
                // still observe the save as complete once load() returns.
                await Task.detached(priority: .utility) {
                    cache.save(toSave, classification: classification)
                }.value
            }
            // Only apply this fetch if nothing newer has started since -- a stale,
            // slower call must never overwrite a faster/later one's results.
            if generation == loadGeneration {
                if let positionSnapshot {
                    positionStore?.reconcileFreshServerPositions(
                        Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.resumeSecs) }),
                        capturedBy: positionSnapshot
                    )
                }
                videos = fetched
            }
        } catch {
            // A cancelled fetch is routine SwiftUI lifecycle (.task and .refreshable
            // cancel their work on view updates, and a newer load supersedes an older
            // one). It says nothing about the server, so leave the list and errorText
            // untouched rather than banner it or fall back to stale cache.
            if Self.isCancellation(error) { return }
            if let cached = await loadCache(), generation == loadGeneration {
                videos = cached
            }
            if generation == loadGeneration {
                report(error)
            }
        }
    }

    /// True for routine task cancellation -- SwiftUI cancelling a `.task`/`.refreshable`,
    /// or a newer request superseding an older one. Never a server-side failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Surfaces a failure to the user, swallowing cancellations.
    private func report(_ error: Error) {
        if Self.isCancellation(error) { return }
        errorText = String(describing: error)
    }

    /// Optimistically re-buckets the video. A `promoted` response means the
    /// server moved the file into Plex and deleted the row, so the video is
    /// dropped from the list and its download purged instead.
    public func classify(id: Int, to classification: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos
        videos[index] = videos[index].withClassification(classification)
        do {
            let result = try await api.classify(id: id, classification: classification)
            if result.promoted {
                videos.removeAll { $0.id == id }
                mediaCache?.removeAllCached(id: id)
                // Server hard-deletes the row on promotion, so re-fetch + re-persist
                // the list now -- otherwise the on-disk cache still contains this
                // video and a future bootLoad() renders it as a ghost card whose
                // stream 404s and whose local file was just purged above.
                await load()
            } else if !result.ok {
                videos = previous
            }
        } catch {
            videos = previous
            report(error)
        }
    }

    public func chooseVersion(id: Int, versionId: Int) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withChosenVersion(versionId)
        do {
            let ok = try await api.chooseVersion(id: id, versionId: versionId)
            if !ok { videos[index] = previous }
        } catch {
            videos[index] = previous
            report(error)
        }
    }

    /// Optimistically records the chosen audio language, then reloads so a
    /// server-triggered re-conversion ("converting" status) shows up.
    public func chooseAudio(id: Int, lang: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        videos[index] = videos[index].withAudioLang(lang)
        do {
            let ok = try await api.chooseAudio(id: id, lang: lang)
            if ok {
                await load()
            } else {
                videos[index] = previous
            }
        } catch {
            videos[index] = previous
            report(error)
        }
    }

    /// Deletes on the server, then refreshes the list (and cache) from the API.
    public func delete(id: Int) async {
        do {
            _ = try await api.delete(id: id)
            await load()
        } catch {
            report(error)
        }
    }

    public func upload(url: String) async {
        do {
            _ = try await api.upload(url: url)
            await load()
        } catch {
            report(error)
        }
    }

    /// Scan the server-side Plex library, then reload the list.
    /// A failed scan surfaces in errorText but still refreshes the list.
    public func refreshLibrary() async {
        var scanErrorText: String?
        do {
            _ = try await api.scanLibrary()
        } catch {
            if !Self.isCancellation(error) { scanErrorText = String(describing: error) }
        }
        await load()
        // If the scan failed but load() itself succeeded (errorText is nil),
        // restore the scan failure so it still surfaces to the user. If load()
        // failed too, its error is more relevant and takes precedence.
        if let scanErrorText, errorText == nil {
            errorText = scanErrorText
        }
    }

    /// Kicks off server-side conversion (if needed) and polls until the video
    /// is streamable. Throws PrepareError when the server reports a failed conversion.
    public func ensureReady(id: Int, bulk: Bool = false, pollIntervalSeconds: Double = 2.0) async throws -> Video {
        let status = try await api.prepare(id: id, bulk: bulk)
        if status == "done" {
            return try await api.video(id: id)
        }
        while true {
            let video = try await api.video(id: id)
            if video.status == "done" { return video }
            if let message = video.errorMsg, !message.isEmpty {
                throw PrepareError.conversionFailed(message)
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }

    /// Wipes the on-disk offline list cache and empties the in-memory list.
    /// The next `load()` repopulates both from the server.
    public func clearListCache() {
        cache?.clear()
        videos = []
    }
}
