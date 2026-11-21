import Foundation
import Combine

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
    /// A short confirmation for the grid to show and clear (not an error).
    @Published public var noticeText: String?

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
    /// Bumped only by local mutations that make an in-flight fetch's *contents*
    /// stale -- a group move or a removed row read before the change landed.
    /// Separate from `loadGeneration`, which a mere tab switch also bumps:
    /// a superseded load still holds a correct list
    /// for the feed it asked about, and its cache write is keyed by that feed, so
    /// dropping it on a tab switch just leaves that feed's cache empty.
    private var contentInvalidation = 0
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
        let invalidation = contentInvalidation
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
            if let cache, invalidation == contentInvalidation {
                let toSave = fetched
                let previousWrite = cacheWriteTask
                let writeTask = Task.detached(priority: .utility) {
                    if let previousWrite { await previousWrite.value }
                    guard await self.contentInvalidation == invalidation else { return }
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
        if error is DownloadPausedError { return true }
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
        contentInvalidation += 1
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
        loadGeneration += 1
        contentInvalidation += 1
        isLoading = false
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

    /// Clears a video's red dot the moment it starts playing, without waiting
    /// for the next list fetch. Local only: the server learns of the play from
    /// `POST /played`, and the next `load()` brings back its own answer.
    public func markWatched(id: Int) {
        guard let index = videos.firstIndex(where: { $0.id == id }),
              videos[index].unwatched else { return }
        videos[index] = videos[index].markingWatched()
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

    public func sendToYoto(id: Int) async {
        do {
            try await api.sendToYoto(id: id)
            noticeText = "Sent to Yoto de Elisa"
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

    /// Pull-to-refresh. Runs in its own unstructured task because SwiftUI
    /// cancels a `.refreshable` action as soon as the view re-renders -- and
    /// `load()` re-renders it itself by flipping `isLoading`. The cancelled
    /// fetch then returned silently with the server's answer thrown away, so a
    /// pull never showed a new video while leaving the group and coming back
    /// (the same request, from a `.task`) did.
    public func refresh() async {
        await Task { await load() }.value
    }

    /// Wipes the on-disk offline list cache and empties the in-memory list.
    /// The next `load()` repopulates both from the server.
    public func clearListCache() {
        cache?.clear()
        videos = []
    }
}
