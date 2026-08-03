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
    private struct GroupMutation {
        let id: Int
        let request: UUID
        let sequence: Int
        let groupID: Int
        let affectedGroupIDs: Set<Int>
    }

    private struct ConfirmedGroup {
        let sequence: Int
        let groupID: Int?
    }

    @Published public private(set) var videos: [Video] = []
    @Published public var feed: Feed {
        didSet { defaults.set(feed.storageKey, forKey: Self.feedKey) }
    }
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI
    private let cache: VideoListCaching?
    private let mediaCache: MediaCaching?
    private let positionStore: ResumePositionStore?
    private let defaults: UserDefaults
    // New key spelling on purpose: the old "selectedClassification" holds a
    // group *name*, which means nothing now. Orphaning it is cheaper and safer
    // than translating it, and costs one launch on the Videos tab root.
    private static let feedKey = "selectedFeed"

    /// Bumped by every switchFeed()/load() invocation so a stale, still-in-flight
    /// call can tell it's been superseded and must not clobber `videos`/`isLoading`
    /// with results that no longer match the current tab/request.
    private var loadGeneration = 0
    private var groupMutationSequence = 0
    private var groupMutations: [Int: GroupMutation] = [:]
    private var confirmedGroups: [Int: ConfirmedGroup] = [:]
    private var cacheWriteTask: Task<Void, Never>?

    public init(api: VideoAPI, cache: VideoListCaching? = nil,
                mediaCache: MediaCaching? = nil,
                positionStore: ResumePositionStore? = nil,
                defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.mediaCache = mediaCache
        self.positionStore = positionStore
        self.defaults = defaults
        self.feed = defaults.string(forKey: Self.feedKey).flatMap(Feed.init(storageKey:)) ?? .all
    }

    /// Reads + JSON-decodes the persisted list off the main actor. Done inline it
    /// blocked the main thread at startup long enough to trip Sentry's app-hang
    /// detector (PATATATUBE-3, NSFileHandle.read during first render).
    private func loadCache() async -> [Video]? {
        guard let cache else { return nil }
        let feed = self.feed
        return await Task.detached(priority: .utility) {
            cache.load(feed: feed)
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

    /// Tab-switch path: swap to the new feed's cached list instantly
    /// (or an empty list, which the grid renders as skeletons), then refresh
    /// from the network. Mirrors bootLoad()'s cache-first behavior so switching
    /// tabs never lingers on the previous feed's videos.
    ///
    /// `feed`, `videos`, and `isLoading` are all updated synchronously, in that
    /// order, before the first `await`. This closes the MainActor-visible window
    /// where `feed` already reflects the new tab but `videos`/`isLoading` still
    /// reflect the old one -- `loadCache()` hops to a background thread internally,
    /// so any state left stale going into that suspension could otherwise render.
    ///
    /// `loadGeneration` guards against a second, faster tab switch landing while
    /// this one is still awaiting its cache read or network fetch: each call
    /// captures its own generation and only applies what it fetches if no newer
    /// switchFeed()/load() call has started in the meantime.
    public func switchFeed(to value: Feed) async {
        loadGeneration += 1
        let generation = loadGeneration
        feed = value
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
            let requestedFeed = feed
            let fetched = try await api.videos(feed: requestedFeed)
            // Encode + atomic disk write off the main actor: doing it inline here
            // (this method is @MainActor) blocked the main thread long enough to
            // trip Sentry's app-hang detector (PATATATUBE-2, NSFileHandle.write).
            if let cache, generation == loadGeneration {
                let toSave = fetched
                let previousWrite = cacheWriteTask
                let writeTask = Task.detached(priority: .utility) {
                    if let previousWrite { await previousWrite.value }
                    guard await self.loadGeneration == generation else { return }
                    cache.save(toSave, feed: requestedFeed)
                }
                cacheWriteTask = writeTask
                await writeTask.value
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

    private func ownsGroupMutation(id: Int, request: UUID) -> Bool {
        groupMutations[id]?.request == request
    }

    private func reconcileGroupMutationCache(
        id: Int, groupID: Int?, groupIDs: Set<Int>, request: UUID
    ) async {
        guard let cache else { return }
        let feeds = [Feed.all] + groupIDs.sorted().map { Feed.group(id: $0) }
        let previousWrite = cacheWriteTask
        let writeTask = Task.detached(priority: .utility) {
            if let previousWrite { await previousWrite.value }
            for feed in feeds {
                guard await self.ownsGroupMutation(id: id, request: request) else { return }
                guard var videos = cache.load(feed: feed) else { continue }
                guard await self.ownsGroupMutation(id: id, request: request) else { return }
                switch feed {
                case .all:
                    if let index = videos.firstIndex(where: { $0.id == id }) {
                        videos[index] = videos[index].withGroupID(groupID)
                    }
                case .group(let cachedGroupID):
                    if groupID == cachedGroupID {
                        if let index = videos.firstIndex(where: { $0.id == id }) {
                            videos[index] = videos[index].withGroupID(groupID)
                        }
                    } else {
                        videos.removeAll { $0.id == id }
                    }
                case .plex:
                    break
                }
                cache.save(videos, feed: feed)
            }
        }
        cacheWriteTask = writeTask
        await writeTask.value
    }

    private func removeDeletedVideo(id: Int) async {
        var groupIDs = groupMutations[id]?.affectedGroupIDs ?? []
        if let groupID = videos.first(where: { $0.id == id })?.groupID {
            groupIDs.insert(groupID)
        }
        if let groupID = confirmedGroups[id]?.groupID { groupIDs.insert(groupID) }
        groupMutations[id] = nil
        confirmedGroups[id] = nil
        videos.removeAll { $0.id == id }

        guard let cache else { return }
        let feeds = [Feed.all] + groupIDs.sorted().map { Feed.group(id: $0) }
        let previousWrite = cacheWriteTask
        let writeTask = Task.detached(priority: .utility) {
            if let previousWrite { await previousWrite.value }
            for feed in feeds {
                guard var videos = cache.load(feed: feed) else { continue }
                videos.removeAll { $0.id == id }
                cache.save(videos, feed: feed)
            }
        }
        cacheWriteTask = writeTask
        await writeTask.value
    }

    private func confirmGroupMutation(_ mutation: GroupMutation) {
        guard let confirmed = confirmedGroups[mutation.id],
              mutation.sequence > confirmed.sequence else { return }
        confirmedGroups[mutation.id] = ConfirmedGroup(
            sequence: mutation.sequence, groupID: mutation.groupID
        )
        if groupMutations[mutation.id] == nil { groupMutations[mutation.id] = mutation }
    }

    private func finishGroupMutation(_ mutation: GroupMutation, succeeded: Bool) async -> Bool {
        guard ownsGroupMutation(id: mutation.id, request: mutation.request) else {
            return false
        }
        while true {
            let confirmed = confirmedGroups[mutation.id]
            let settledGroupID = succeeded ? mutation.groupID : confirmed?.groupID
            let settledSequence = succeeded ? mutation.sequence : (confirmed?.sequence ?? -1)

            switch feed {
            case .all:
                if let index = videos.firstIndex(where: { $0.id == mutation.id }) {
                    videos[index] = videos[index].withGroupID(settledGroupID)
                }
            case .group(let groupID):
                if settledGroupID == groupID {
                    if let index = videos.firstIndex(where: { $0.id == mutation.id }) {
                        videos[index] = videos[index].withGroupID(settledGroupID)
                    }
                } else {
                    videos.removeAll { $0.id == mutation.id }
                }
            case .plex:
                break
            }
            await reconcileGroupMutationCache(
                id: mutation.id, groupID: settledGroupID,
                groupIDs: mutation.affectedGroupIDs, request: mutation.request
            )
            guard ownsGroupMutation(id: mutation.id, request: mutation.request) else {
                return false
            }
            if succeeded || (confirmedGroups[mutation.id]?.sequence ?? -1) == settledSequence {
                groupMutations[mutation.id] = nil
                return true
            }
        }
    }

    public func setGroup(id: Int, groupID: Int) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index]
        guard !previous.isPlexItem else { return }
        let updated = previous.withGroupID(groupID)
        let activeMutation = groupMutations[id]
        groupMutationSequence += 1
        if activeMutation == nil {
            confirmedGroups[id] = ConfirmedGroup(
                sequence: groupMutationSequence - 1, groupID: previous.groupID
            )
        }
        var affectedGroupIDs = activeMutation?.affectedGroupIDs ?? []
        if let previousGroupID = previous.groupID { affectedGroupIDs.insert(previousGroupID) }
        affectedGroupIDs.insert(groupID)
        let mutation = GroupMutation(
            id: id, request: UUID(), sequence: groupMutationSequence, groupID: groupID,
            affectedGroupIDs: affectedGroupIDs
        )
        groupMutations[id] = mutation
        videos[index] = updated
        do {
            let succeeded = try await api.setGroup(id: id, groupID: groupID)
            if succeeded { confirmGroupMutation(mutation) }
            _ = await finishGroupMutation(mutation, succeeded: succeeded)
        } catch {
            if await finishGroupMutation(mutation, succeeded: false) { report(error) }
        }
    }

    /// Promoting moves the file into Plex and deletes the row, so drop it from
    /// the list and purge its download before refreshing the persisted list.
    public func promote(id: Int, kind: PlexKind) async {
        guard videos.contains(where: { $0.id == id }) else { return }
        do {
            guard try await api.promote(id: id, kind: kind) else { return }
            mediaCache?.removeAllCached(id: id)
            await removeDeletedVideo(id: id)
            // Server hard-deletes the row on promotion, so re-fetch + re-persist
            // the list now -- otherwise the on-disk cache still contains this
            // video and a future bootLoad() renders it as a ghost card whose
            // stream 404s and whose local file was just purged above.
            await load()
        } catch {
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
            if try await api.delete(id: id) {
                await removeDeletedVideo(id: id)
            }
            await load()
        } catch {
            report(error)
        }
    }

    public func upload(url: String) async {
        do {
            let groupID: Int?
            if case .group(let id) = feed { groupID = id } else { groupID = nil }
            _ = try await api.upload(url: url, groupID: groupID)
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
