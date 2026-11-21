import Testing
import Foundation
@testable import PatataTubeKit

private func makeVideo(id: Int, groupID: Int? = 1,
                       status: String = "completed",
                       errorMsg: String? = nil, previewUrl: String? = nil, chosenVersionId: Int? = nil,
                       resumeSecs: Double = 0) -> Video {
    return Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: previewUrl, groupID: groupID, position: id,
          status: status, errorMsg: errorMsg, streamPath: "/videos/\(id)/stream",
          chosenVersionId: chosenVersionId, resumeSecs: resumeSecs)
}

private func makeDefaults() -> UserDefaults {
    let suite = "video-store.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class FakeAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var setGroupResult = true
    var uploadId = 100
    var throwOnSetGroup = false
    var throwOnVideos = false
    var videosError: Error?
    private(set) var loadCount = 0
    private(set) var lastFeed: Feed?
    /// Fires inside videos(...) before it returns, so a test can observe
    /// VideoStore's state after the synchronous cache swap but before the
    /// network result lands.
    var beforeVideosReturn: (@Sendable () async -> Void)?
    var videosHook: (@Sendable (Feed) async throws -> [Video])?

    func videos(feed: Feed) async throws -> [Video] {
        loadCount += 1
        lastFeed = feed
        if let videosHook { return try await videosHook(feed) }
        if let beforeVideosReturn { await beforeVideosReturn() }
        if let videosError { throw videosError }
        if throwOnVideos { throw APIError.badStatus(503) }
        switch feed {
        case .all: return videosToReturn
        case .group(let id): return videosToReturn.filter { $0.groupID == id }
        }
    }
    /// Thrown by every mutating endpoint, so one hook covers them all.
    var mutationError: Error?
    var setGroupHook: (@Sendable (Int, Int) async throws -> Bool)?
    private(set) var setGroupRequests: [(id: Int, groupID: Int)] = []
    private(set) var uploadGroupIDs: [Int?] = []
    func setGroup(id: Int, groupID: Int) async throws -> Bool {
        if let mutationError { throw mutationError }
        if throwOnSetGroup { throw APIError.badStatus(500) }
        setGroupRequests.append((id, groupID))
        if let setGroupHook { return try await setGroupHook(id, groupID) }
        return setGroupResult
    }
    func upload(url: String, groupID: Int?) async throws -> Int {
        if let mutationError { throw mutationError }
        uploadGroupIDs.append(groupID)
        return uploadId
    }
    var deleteResult = true
    private(set) var deletedIds: [Int] = []
    func delete(id: Int) async throws -> Bool {
        if let mutationError { throw mutationError }
        deletedIds.append(id)
        if deleteResult { videosToReturn.removeAll { $0.id == id } }
        return deleteResult
    }
    var videoResults: [Video] = []
    private(set) var videoCalls = 0
    private(set) var savedPositions: [(id: Int, secs: Double)] = []

    func savePosition(id: Int, secs: Double) async throws {
        if let mutationError { throw mutationError }
        savedPositions.append((id, secs))
    }
    func video(id: Int) async throws -> Video {
        videoCalls += 1
        return videoResults.isEmpty ? makeVideo(id: id) : videoResults[min(videoCalls, videoResults.count) - 1]
    }
    func imageData(path: String) async throws -> Data { Data() }
}

@MainActor @Test func defaultsToAllWithNoPersistedFeed() {
    let store = VideoStore(api: FakeAPI(), defaults: makeDefaults())
    #expect(store.feed == .all)
}

@MainActor @Test func persistsAndRestoresTheFeed() async {
    let defaults = makeDefaults()
    let store = VideoStore(api: FakeAPI(), defaults: defaults)
    await store.switchFeed(to: .group(id: 7))
    #expect(VideoStore(api: FakeAPI(), defaults: defaults).feed == .group(id: 7))
}

@MainActor @Test func switchFeedRequestsTheNewFeed() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 9))
    #expect(api.lastFeed == .group(id: 9))
}

private final class BlockingSaveCache: VideoListCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var saveStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func save(_ videos: [Video], feed: Feed) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            saveStarted = true
            defer { startedWaiter = nil }
            return startedWaiter
        }
        waiter?.resume()
        releaseGate.wait()
    }

    func waitForSaveToStart() async {
        if lock.withLock({ saveStarted }) { return }
        await withCheckedContinuation { continuation in
            let alreadyStarted = lock.withLock { () -> Bool in
                if saveStarted { return true }
                startedWaiter = continuation
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func releaseSave() { releaseGate.signal() }
    func load(feed: Feed) -> [Video]? { nil }
    func clear() {}
}

private final class DelayedVideoListCache: VideoListCaching, @unchecked Sendable {
    private let backing = VideoListCache(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("delayed-vlc-\(UUID().uuidString)")
    )
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var delayedFeed: Feed?
    private var saveStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func delayNextSave(feed: Feed) {
        lock.withLock {
            delayedFeed = feed
            saveStarted = false
        }
    }

    func save(_ videos: [Video], feed: Feed) {
        let delay = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            guard delayedFeed == feed else { return (false, nil) }
            delayedFeed = nil
            saveStarted = true
            defer { startedWaiter = nil }
            return (true, startedWaiter)
        }
        delay.1?.resume()
        if delay.0 { releaseGate.wait() }
        backing.save(videos, feed: feed)
    }

    func waitForDelayedSave() async {
        if lock.withLock({ saveStarted }) { return }
        await withCheckedContinuation { continuation in
            let alreadyStarted = lock.withLock { () -> Bool in
                if saveStarted { return true }
                startedWaiter = continuation
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func releaseDelayedSave() { releaseGate.signal() }
    func load(feed: Feed) -> [Video]? { backing.load(feed: feed) }
    func clear() { backing.clear() }
}

private final class BlockingLoadCache: VideoListCaching, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var videos: [Feed: [Video]]
    private var groupLoadStarted = false
    private var groupLoadWaiter: CheckedContinuation<Void, Never>?

    init(videos: [Feed: [Video]]) {
        self.videos = videos
    }

    func save(_ videos: [Video], feed: Feed) {
        lock.withLock { self.videos[feed] = videos }
    }

    func load(feed: Feed) -> [Video]? {
        if feed == .group(id: 1) {
            let firstLoad = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
                guard !groupLoadStarted else { return (false, nil) }
                groupLoadStarted = true
                defer { groupLoadWaiter = nil }
                return (true, groupLoadWaiter)
            }
            if firstLoad.0 {
                firstLoad.1?.resume()
                releaseGate.wait()
            }
        }
        return lock.withLock { videos[feed] }
    }

    func waitForGroupLoad() async {
        if lock.withLock({ groupLoadStarted }) { return }
        await withCheckedContinuation { continuation in
            let alreadyStarted = lock.withLock { () -> Bool in
                if groupLoadStarted { return true }
                groupLoadWaiter = continuation
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func releaseGroupLoad() { releaseGate.signal() }
    func cached(feed: Feed) -> [Video]? { lock.withLock { videos[feed] } }
    func clear() { lock.withLock { videos = [:] } }
}

private actor GroupMoveGate {
    private var arrived: Set<Int> = []
    private var arrivalWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func arrive(_ id: Int) async {
        arrived.insert(id)
        arrivalWaiters.removeValue(forKey: id)?.resume()
        await withCheckedContinuation { releaseWaiters[id] = $0 }
    }

    func waitForArrival(_ id: Int) async {
        guard !arrived.contains(id) else { return }
        await withCheckedContinuation { arrivalWaiters[id] = $0 }
    }

    func release(_ id: Int) {
        releaseWaiters.removeValue(forKey: id)?.resume()
    }
}

private actor StaleVideoFetch {
    private let stale: [Video]
    private var used = false
    private var arrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ stale: [Video]) { self.stale = stale }

    func fetch() async -> [Video] {
        guard !used else { return [] }
        used = true
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return stale
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor @Test func successfulPositionSaveWinsOverStaleRowAndOfflineCacheUntilFreshList() async throws {
    let api = FakeAPI()
    let stale = makeVideo(id: 7, groupID: nil, resumeSecs: 10)
    let cache = tempCache()
    cache.save([stale], feed: .all)
    let defaults = try #require(UserDefaults(suiteName: "position-grid-\(UUID().uuidString)"))
    let positions = ResumePositionStore(defaults: defaults, serverURL: URL(string: "https://srv.test"))
    let reporter = PlaybackPositionReporter(api: api, store: positions)

    await reporter.record(id: 7, secs: 120, duration: 1_000, force: true)

    #expect(api.savedPositions.map(\.secs) == [120])
    #expect(positions.pending().isEmpty)
    #expect(ResumeDecision.decide(
        resumeSecs: positions.resolved(server: stale.resumeSecs, for: stale.id),
        remembersPosition: true
    ) == .ask(secs: 120))

    api.videosError = URLError(.notConnectedToInternet)
    let videoStore = VideoStore(api: api, cache: cache, positionStore: positions, defaults: defaults)
    await videoStore.load()
    let cached = try #require(videoStore.videos.first)
    #expect(ResumeDecision.decide(
        resumeSecs: positions.resolved(server: cached.resumeSecs, for: cached.id),
        remembersPosition: true
    ) == .ask(secs: 120))
}

@MainActor @Test func freshOnlineListReplacesSyncedLocalPosition() async throws {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 7, resumeSecs: 45)]
    let defaults = try #require(UserDefaults(suiteName: "position-fresh-\(UUID().uuidString)"))
    let positions = ResumePositionStore(defaults: defaults, serverURL: URL(string: "https://srv.test"))
    positions.setLocal(120, for: 7)
    positions.markSynced(id: 7)
    let videoStore = VideoStore(api: api, positionStore: positions, defaults: defaults)

    await videoStore.load()

    let fresh = try #require(videoStore.videos.first)
    #expect(positions.resolved(server: fresh.resumeSecs, for: fresh.id) == 45)
}

@MainActor @Test func listFetchedBeforeSuccessfulSaveCannotAcknowledgeNewerPosition() async throws {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 7, resumeSecs: 10)]
    let cache = BlockingSaveCache()
    let defaults = try #require(UserDefaults(suiteName: "position-cache-race-\(UUID().uuidString)"))
    let positions = ResumePositionStore(defaults: defaults)
    let reporter = PlaybackPositionReporter(api: api, store: positions)
    let videoStore = VideoStore(
        api: api, cache: cache, positionStore: positions, defaults: defaults
    )

    let load = Task { await videoStore.load() }
    await cache.waitForSaveToStart()
    await reporter.record(id: 7, secs: 120, duration: 1_000, force: true)
    cache.releaseSave()
    await load.value

    let stale = try #require(videoStore.videos.first)
    #expect(positions.pending().isEmpty)
    #expect(positions.resolved(server: stale.resumeSecs, for: stale.id) == 120)
}

@Test func cacheLocalURLUsesVersionIdWhenPresent() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CacheManager(root: root)

    #expect(cache.localURL(for: 7).lastPathComponent == "7.mp4")
    #expect(cache.localURL(for: 7, versionId: 20).lastPathComponent == "7.v20.mp4")
}

@MainActor @Test func loadPopulatesVideos() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()
    #expect(store.videos.count == 2)
    #expect(store.isLoading == false)
    #expect(store.errorText == nil)
}

@MainActor @Test func setGroupUpdatesTheListAndCacheOnSuccess() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    await store.setGroup(id: 1, groupID: 2)
    #expect(api.setGroupRequests.map(\.id) == [1])
    #expect(api.setGroupRequests.map(\.groupID) == [2])
    #expect(store.videos[0].groupID == 2)
    #expect(cache.load(feed: .all)?[0].groupID == 2)
}

@MainActor @Test func setGroupRemovesConfirmedMoveFromSourceGroupFeedAndCache() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    await store.setGroup(id: 1, groupID: 2)

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
}

@MainActor @Test func setGroupDoesNotReportServerNotOk() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    api.setGroupResult = false
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()
    await store.setGroup(id: 1, groupID: 2)
    #expect(store.errorText == nil)
    #expect(store.videos[0].groupID == 1)
}

@MainActor @Test func setGroupSetsErrorOnThrow() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    api.throwOnSetGroup = true
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()
    await store.setGroup(id: 1, groupID: 2)
    #expect(store.errorText != nil)
    #expect(store.videos[0].groupID == 1)
}

@MainActor @Test func olderSetGroupFailureDoesNotRevertANewerGroup() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    api.setGroupHook = { _, groupID in
        if groupID == 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
            throw APIError.badStatus(500)
        }
        return true
    }
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    async let first: Void = store.setGroup(id: 1, groupID: 2)
    try? await Task.sleep(nanoseconds: 5_000_000)
    async let second: Void = store.setGroup(id: 1, groupID: 3)
    _ = await (first, second)

    #expect(store.videos[0].groupID == 3)
}

@MainActor @Test func concurrentMovesOfDifferentVideosBothLeaveTheSourceFeed() async {
    let api = FakeAPI()
    api.videosToReturn = [
        makeVideo(id: 1),
        makeVideo(id: 2),
    ]
    api.setGroupHook = { id, _ in
        if id == 1 { try await Task.sleep(nanoseconds: 50_000_000) }
        return true
    }
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    async let first: Void = store.setGroup(id: 1, groupID: 2)
    try? await Task.sleep(nanoseconds: 5_000_000)
    async let second: Void = store.setGroup(id: 2, groupID: 2)
    _ = await (first, second)

    #expect(store.videos.isEmpty)
}

@MainActor @Test func concurrentGroupMoveFailurePersistsTheSettledSourceFeed() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let gate = GroupMoveGate()
    api.setGroupHook = { id, _ in
        await gate.arrive(id)
        return id == 1
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    async let first: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(1)
    async let second: Void = store.setGroup(id: 2, groupID: 2)
    await gate.waitForArrival(2)
    await gate.release(1)
    await first
    await gate.release(2)
    await second

    #expect(store.videos.map(\.id) == [2])
    #expect(store.videos[0].groupID == 1)
    #expect(cache.load(feed: .group(id: 1))?.map(\.id) == [2])
    #expect(cache.load(feed: .group(id: 1))?[0].groupID == 1)
}

@MainActor @Test func groupMoveInAnotherFeedDoesNotDelayTheSettledFeedCache() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1), makeVideo(id: 2, groupID: 2)]
    let gate = GroupMoveGate()
    api.setGroupHook = { id, _ in
        await gate.arrive(id)
        return true
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    async let first: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(1)
    await store.switchFeed(to: .group(id: 2))
    async let second: Void = store.setGroup(id: 2, groupID: 3)
    await gate.waitForArrival(2)
    await gate.release(2)
    await second

    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)

    await gate.release(1)
    await first
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
}

@MainActor @Test func newerCrossFeedMoveWinsAndReconcilesEveryAffectedCache() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return true
    }
    let cache = tempCache()
    cache.save([], feed: .group(id: 2))
    cache.save([], feed: .group(id: 3))
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    await store.switchFeed(to: .all)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await store.switchFeed(to: .group(id: 99))

    await gate.release(3)
    await newer

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .all)?.first?.groupID == 3)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 3))?.isEmpty == true)

    await gate.release(2)
    await older

    #expect(cache.load(feed: .all)?.first?.groupID == 3)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 3))?.isEmpty == true)
}

@MainActor @Test func newerSameVideoMovePersistsBeforeOlderRequestCompletes() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return true
    }
    let cache = tempCache()
    cache.save([makeVideo(id: 1, groupID: 1)], feed: .group(id: 1))
    cache.save([], feed: .group(id: 2))
    cache.save([], feed: .group(id: 3))
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await gate.release(3)
    await newer

    #expect(cache.load(feed: .all)?.first?.groupID == 3)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 3))?.isEmpty == true)

    await gate.release(2)
    await older
    #expect(cache.load(feed: .all)?.first?.groupID == 3)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 3))?.isEmpty == true)
}

@MainActor @Test func newerAllFeedMoveEvictsItsSourceGroupWhileOlderMoveIsPending() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return true
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    await store.switchFeed(to: .all)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await store.switchFeed(to: .group(id: 1))

    await gate.release(3)
    await newer

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)

    await gate.release(2)
    await older
}

@MainActor @Test func settledMoveDoesNotPersistAnotherVideosOptimisticGroup() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let gate = GroupMoveGate()
    api.setGroupHook = { id, _ in
        if id == 2 { await gate.arrive(id) }
        return true
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let pending: Void = store.setGroup(id: 2, groupID: 2)
    await gate.waitForArrival(2)
    await store.setGroup(id: 1, groupID: 3)

    #expect(cache.load(feed: .all)?.first(where: { $0.id == 1 })?.groupID == 3)
    #expect(cache.load(feed: .all)?.first(where: { $0.id == 2 })?.groupID == 1)

    await gate.release(2)
    await pending
}

@MainActor @Test func newerFailureKeepsPriorSuccessfulSourceEviction() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return groupID == 2
    }
    let cache = tempCache()
    cache.save([makeVideo(id: 1, groupID: 1)], feed: .group(id: 1))
    cache.save([], feed: .group(id: 2))
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 1)
    await gate.waitForArrival(1)

    await gate.release(2)
    await older
    await gate.release(1)
    await newer

    #expect(store.videos.first?.groupID == 2)
    #expect(cache.load(feed: .all)?.first?.groupID == 2)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
}

@MainActor @Test func olderSuccessSettlesAfterNewerFailureFinishesFirst() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return groupID == 2
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await gate.release(3)
    await newer

    await gate.release(2)
    await older

    #expect(store.videos.first?.groupID == 2)
    #expect(cache.load(feed: .all)?.first?.groupID == 2)
}

@MainActor @Test func olderSuccessSettlesWhileNewerFailureCacheWriteIsInFlight() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return groupID == 2
    }
    let cache = DelayedVideoListCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    cache.delayNextSave(feed: .all)
    await gate.release(3)
    await cache.waitForDelayedSave()

    await gate.release(2)
    await older
    cache.releaseDelayedSave()
    await newer

    #expect(store.videos.first?.groupID == 2)
    #expect(cache.load(feed: .all)?.first?.groupID == 2)
}

@MainActor @Test func twoFailedMovesRollBackToTheLastConfirmedGroup() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        return false
    }
    let cache = tempCache()
    cache.save([makeVideo(id: 1, groupID: 1)], feed: .group(id: 1))
    cache.save([], feed: .group(id: 2))
    cache.save([], feed: .group(id: 3))
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await gate.release(2)
    await older
    await gate.release(3)
    await newer

    #expect(store.videos.first?.groupID == 1)
    #expect(cache.load(feed: .all)?.first?.groupID == 1)
    #expect(cache.load(feed: .group(id: 1))?.map(\.id) == [1])
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 3))?.isEmpty == true)
}

@MainActor @Test func deletedVideoIsNotResurrectedByDelayedGroupFailure() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        await gate.arrive(groupID)
        throw APIError.badStatus(500)
    }
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let move: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    await store.delete(id: 1)
    await gate.release(2)
    await move

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .all)?.isEmpty == true)
    #expect(store.errorText == nil)
}

@MainActor @Test func deletePurgesCachesAfterAlreadyStartedGroupSave() async {
    let video = makeVideo(id: 1, groupID: 1)
    let api = FakeAPI()
    api.videosToReturn = [video]
    let cache = DelayedVideoListCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))
    cache.save([video], feed: .all)
    cache.save([video], feed: .group(id: 2))
    cache.delayNextSave(feed: .all)

    async let move: Void = store.setGroup(id: 1, groupID: 2)
    await cache.waitForDelayedSave()
    async let deletion: Void = store.delete(id: 1)
    cache.releaseDelayedSave()
    _ = await (move, deletion)

    #expect(cache.load(feed: .all)?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 1))?.isEmpty == true)
    #expect(cache.load(feed: .group(id: 2))?.isEmpty == true)
}

@MainActor @Test func staleLoadCannotRewriteCacheAfterDelete() async {
    let video = makeVideo(id: 1, groupID: 1)
    let api = FakeAPI()
    api.videosToReturn = [video]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    let fetch = StaleVideoFetch([video])
    api.videosHook = { _ in await fetch.fetch() }

    async let staleLoad: Void = store.load()
    await fetch.waitForArrival()
    await store.delete(id: 1)
    await fetch.release()
    await staleLoad

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .all)?.isEmpty == true)
}

@MainActor @Test func staleLoadCannotOverwriteAConfirmedGroupMove() async {
    let video = makeVideo(id: 1, groupID: 1)
    let api = FakeAPI()
    api.videosToReturn = [video]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    let fetch = StaleVideoFetch([video])
    api.videosHook = { _ in await fetch.fetch() }

    async let staleLoad: Void = store.load()
    await fetch.waitForArrival()
    await store.setGroup(id: 1, groupID: 2)
    await fetch.release()
    await staleLoad

    #expect(store.videos.first?.groupID == 2)
    #expect(cache.load(feed: .all)?.first?.groupID == 2)
}

@MainActor @Test func movingTheLastGroupItemClearsAnInvalidatedLoad() async {
    let video = makeVideo(id: 1, groupID: 1)
    let api = FakeAPI()
    api.videosToReturn = [video]
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 1))
    let fetch = StaleVideoFetch([video])
    api.videosHook = { _ in await fetch.fetch() }

    async let staleLoad: Void = store.load()
    await fetch.waitForArrival()
    #expect(store.isLoading)
    await store.setGroup(id: 1, groupID: 2)

    #expect(store.videos.isEmpty)
    #expect(!store.isLoading)
    await fetch.release()
    await staleLoad
    #expect(!store.isLoading)
}

@MainActor @Test func staleSourceCacheEvictionDoesNotOverwriteNewerSameVideoMove() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 1)]
    let gate = GroupMoveGate()
    api.setGroupHook = { _, groupID in
        if groupID == 1 { await gate.arrive(groupID) }
        return true
    }
    let cache = BlockingLoadCache(videos: [.group(id: 1): [makeVideo(id: 1, groupID: 1)]])
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await cache.waitForGroupLoad()
    async let newer: Void = store.setGroup(id: 1, groupID: 1)
    await gate.waitForArrival(1)
    cache.releaseGroupLoad()
    await older

    #expect(cache.cached(feed: .group(id: 1))?.map(\.id) == [1])

    await gate.release(1)
    await newer

    #expect(cache.cached(feed: .all)?.first?.groupID == 1)
    #expect(cache.cached(feed: .group(id: 1))?.map(\.id) == [1])
}

private func tempCache() -> VideoListCache {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vlc-\(UUID().uuidString)")
    return VideoListCache(root: dir)
}

@MainActor @Test func loadSavesResponseToCache() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    #expect(cache.load(feed: .all)?.count == 2)
}

@MainActor @Test func loadFallsBackToCacheAndSetsErrorWhenNetworkFails() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText?.contains("503") == true)
}

@MainActor @Test func loadSetsErrorWhenNetworkFailsAndNoCache() async {
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    #expect(store.videos.isEmpty)
    #expect(store.errorText != nil)
}

// A cancelled URLSession task (-999) is normal SwiftUI lifecycle -- .task and
// .refreshable cancel their work when the view updates or a newer load
// supersedes them. It is not a failure the user should see.
@MainActor @Test func loadIgnoresURLCancellation() async {
    let api = FakeAPI()
    api.videosError = URLError(.cancelled)
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    #expect(store.errorText == nil)
}

@MainActor @Test func loadIgnoresNSURLCancellation() async {
    let api = FakeAPI()
    api.videosError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    #expect(store.errorText == nil)
}

@MainActor @Test func loadIgnoresTaskCancellation() async {
    let api = FakeAPI()
    api.videosError = CancellationError()
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    #expect(store.errorText == nil)
}

// A cancelled refresh must not wipe out what is already on screen.
@MainActor @Test func loadKeepsExistingVideosOnCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    api.videosError = URLError(.cancelled)
    await store.load()
    #expect(store.videos.map(\.id) == [1, 2])
    #expect(store.errorText == nil)
}

// Same rule for the mutating endpoints: a cancelled write still rolls the
// optimistic edit back (the server never confirmed it), but must not banner.
@MainActor @Test func setGroupIgnoresCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    await store.load()
    api.mutationError = URLError(.cancelled)
    await store.setGroup(id: 1, groupID: 2)
    #expect(store.errorText == nil)
    #expect(store.videos.first?.groupID == 1)
}

@MainActor @Test func deleteIgnoresCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    api.mutationError = URLError(.cancelled)
    await store.delete(id: 1)
    #expect(store.errorText == nil)
}

@MainActor @Test func uploadIgnoresCancellation() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())
    api.mutationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    await store.upload(url: "https://example.com/v")
    #expect(store.errorText == nil)
}

@MainActor @Test func uploadTargetsAndReloadsTheCurrentGroup() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 2))
    api.videosToReturn = [makeVideo(id: api.uploadId, groupID: 2)]

    await store.upload(url: "https://example.com/new")

    #expect(api.uploadGroupIDs.count == 1)
    #expect(api.uploadGroupIDs[0] == 2)
    #expect(api.lastFeed == .group(id: 2))
    #expect(store.videos.map(\.id) == [api.uploadId])
}

// SwiftUI cancels a .refreshable action mid-flight; URLSession then throws
// .cancelled and load() drops the result. refresh() must not inherit that.
@MainActor @Test func refreshSurvivesCancellationOfTheCallingTask() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.switchFeed(to: .group(id: 2))
    api.videosHook = { _ in
        if Task.isCancelled { throw URLError(.cancelled) }
        return [makeVideo(id: 7, groupID: 2)]
    }

    let pull = Task { await store.refresh() }
    pull.cancel()
    await pull.value

    #expect(store.videos.map(\.id) == [7])
}

@MainActor @Test func markWatchedClearsOnlyThatVideosDot() async {
    let api = FakeAPI()
    api.videosToReturn = [
        Video(id: 1, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
              groupID: 1, position: nil, status: "done", errorMsg: nil,
              streamPath: "/s", unwatched: true),
        Video(id: 2, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
              groupID: 1, position: nil, status: "done", errorMsg: nil,
              streamPath: "/s", unwatched: true),
    ]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    store.markWatched(id: 1)

    #expect(store.videos.map(\.unwatched) == [false, true])
}

@Test func unwatchedDecodesAndDefaultsToFalseWhenAbsent() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let with = #"{"id":1,"url":"u","status":"done","stream_path":"/s","unwatched":true}"#
    let without = #"{"id":1,"url":"u","status":"done","stream_path":"/s"}"#
    #expect(try decoder.decode(Video.self, from: Data(with.utf8)).unwatched)
    #expect(try decoder.decode(Video.self, from: Data(without.utf8)).unwatched == false)
    // The copy helpers must carry the flag, not reset it.
    let video = try decoder.decode(Video.self, from: Data(with.utf8))
    #expect(video.withGroupID(nil).unwatched)
}

@MainActor @Test func bootLoadShowsCacheThenRefreshes() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.bootLoad()
    #expect(api.loadCount == 1)               // did hit network to refresh
    #expect(store.videos.map(\.id) == [1, 2]) // ended on fresh data
}

@MainActor @Test func bootLoadServesCacheAndSetsErrorOffline() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.bootLoad()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText?.contains("503") == true)
}

@MainActor @Test func deleteCallsApiThenRefetches() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()          // loadCount == 1
    await store.delete(id: 1)   // delete -> reload
    #expect(api.deletedIds == [1])
    #expect(api.loadCount == 2)
}

@MainActor @Test func clearListCacheEmptiesVideosAndDiskCache() async {
    let cache = tempCache()
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()
    #expect(!store.videos.isEmpty)
    #expect(cache.load(feed: .all) != nil)

    store.clearListCache()

    #expect(store.videos.isEmpty)
    #expect(cache.load(feed: .all) == nil)
}

@MainActor @Test func switchFeedShowsCachedListBeforeNetworkReturns() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9, groupID: 2)], feed: .group(id: 2))
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 2),
                          makeVideo(id: 2, groupID: 2)]
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())

    api.beforeVideosReturn = { @MainActor in
        // Cache swap already happened; network result not yet applied.
        #expect(store.feed == .group(id: 2))
        #expect(store.videos.map(\.id) == [9])
        #expect(store.isLoading == true)
    }
    await store.switchFeed(to: .group(id: 2))

    // After the network returns, the API result replaces the cached list.
    #expect(store.videos.map(\.id) == [1, 2])
    #expect(store.isLoading == false)
    #expect(cache.load(feed: .group(id: 2))?.map(\.id) == [1, 2])
}

@MainActor @Test func switchFeedShowsEmptyThenFillsWhenNoCache() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 5)]
    let store = VideoStore(api: api, cache: tempCache(), defaults: makeDefaults())

    api.beforeVideosReturn = { @MainActor in
        // No cache for "children" -> grid empty (skeletons) while loading.
        #expect(store.videos.isEmpty)
        #expect(store.isLoading == true)
    }
    await store.switchFeed(to: .group(id: 1))

    #expect(store.videos.map(\.id) == [5])
    #expect(store.feed == .group(id: 1))
}

@MainActor @Test func switchFeedNeverShowsPreviousFeedsVideos() async {
    let cache = tempCache()
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 2),
                          makeVideo(id: 7)]
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())

    // Land on "adults" first (populates videos with id 1 and caches it).
    await store.switchFeed(to: .group(id: 2))
    #expect(store.videos.map(\.id) == [1])

    // Switch to "children" (no cache): must not keep showing adults' [1].
    api.beforeVideosReturn = { @MainActor in
        #expect(store.videos.isEmpty)
    }
    await store.switchFeed(to: .group(id: 1))
    #expect(store.videos.map(\.id) == [7])
}

// Two rapid taps -> two overlapping switchFeed() tasks with no cancellation
// between them. The first (slower) fetch must not clobber the second (faster,
// later) one's result once it finally resolves -- the generation guard should
// discard the stale "adults" result in favor of the current "children" tab.
@MainActor @Test func switchFeedRapidDoubleSwitchResolvesToLastFeed() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: 2, previewUrl: "/videos/1/preview", resumeSecs: 10),
                          makeVideo(id: 2, previewUrl: "/videos/2/preview")]
    let defaults = UserDefaults(suiteName: "rapid-filter-\(UUID().uuidString)")!
    let positions = ResumePositionStore(defaults: defaults)
    positions.setLocal(120, for: 1)
    positions.markSynced(id: 1)
    let store = VideoStore(
        api: api, cache: tempCache(), positionStore: positions, defaults: defaults
    )

    // Delay only the "adults" fetch, so it's still in flight when the
    // "children" switch lands and finishes first.
    api.beforeVideosReturn = { @MainActor in
        if store.feed == .group(id: 2) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    async let first: Void = store.switchFeed(to: .group(id: 2))
    try? await Task.sleep(nanoseconds: 5_000_000)
    async let second: Void = store.switchFeed(to: .group(id: 1))
    _ = await (first, second)

    #expect(store.feed == .group(id: 1))
    #expect(store.videos.map(\.id) == [2])
    #expect(store.isLoading == false)
    // The discarded adults response must not clear the local value while its
    // row is absent from the list that actually reached the grid.
    #expect(positions.resolved(server: 10, for: 1) == 120)
}

@MainActor @Test func staleFeedResponseCannotOverwriteTheNewFeedsCache() async {
    let api = FakeAPI()
    api.videosToReturn = [
        makeVideo(id: 1),
        makeVideo(id: 2, groupID: 2),
    ]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())

    api.beforeVideosReturn = { @MainActor in
        if api.lastFeed == .group(id: 1) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    async let first: Void = store.switchFeed(to: .group(id: 1))
    try? await Task.sleep(nanoseconds: 5_000_000)
    async let second: Void = store.switchFeed(to: .group(id: 2))
    _ = await (first, second)

    #expect(cache.load(feed: .group(id: 1))?.map(\.id) == [1])
    #expect(cache.load(feed: .group(id: 2))?.map(\.id) == [2])
}
