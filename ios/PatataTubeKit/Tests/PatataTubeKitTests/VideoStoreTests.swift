import Testing
import Foundation
@testable import PatataTubeKit

private func makeVideo(id: Int, groupID: Int? = 1, plexKind: PlexKind? = nil,
                       status: String = "completed",
                       errorMsg: String? = nil, previewUrl: String? = nil, chosenVersionId: Int? = nil,
                       versions: [VideoVersion] = [], resumeSecs: Double = 0) -> Video {
    return Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: previewUrl, groupID: groupID, plexKind: plexKind, position: id,
          status: status, errorMsg: errorMsg, streamPath: "/videos/\(id)/stream",
          chosenVersionId: chosenVersionId, versions: versions, resumeSecs: resumeSecs)
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

    func videos(feed: Feed) async throws -> [Video] {
        loadCount += 1
        lastFeed = feed
        if let beforeVideosReturn { await beforeVideosReturn() }
        if let videosError { throw videosError }
        if throwOnVideos { throw APIError.badStatus(503) }
        switch feed {
        case .all: return videosToReturn
        case .group(let id): return videosToReturn.filter { $0.groupID == id }
        case .plex(let kind): return videosToReturn.filter { $0.plexKind == kind }
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
        return deleteResult
    }
    var scanResult = ScanResult(added: 0, updated: 0, skipped: 0)
    var throwOnScan = false
    private(set) var scanCalls = 0
    var chooseVersionResult = true
    private(set) var chosenVersions: [(id: Int, versionId: Int)] = []
    var chooseAudioResult = true
    private(set) var chosenAudio: [(id: Int, lang: String)] = []
    var prepareResult = "done"
    var videoResults: [Video] = []
    private(set) var videoCalls = 0
    private(set) var savedPositions: [(id: Int, secs: Double)] = []

    var scanError: Error?
    func scanLibrary() async throws -> ScanResult {
        scanCalls += 1
        if let scanError { throw scanError }
        if throwOnScan { throw APIError.badStatus(500) }
        return scanResult
    }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool {
        if let mutationError { throw mutationError }
        chosenVersions.append((id, versionId))
        return chooseVersionResult
    }
    func chooseAudio(id: Int, lang: String) async throws -> Bool {
        if let mutationError { throw mutationError }
        chosenAudio.append((id, lang))
        return chooseAudioResult
    }
    func savePosition(id: Int, secs: Double) async throws {
        if let mutationError { throw mutationError }
        savedPositions.append((id, secs))
    }
    func prepare(id: Int, bulk: Bool) async throws -> String { prepareResult }
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
    await store.switchFeed(to: .plex(.movies))
    #expect(api.lastFeed == .plex(.movies))
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
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !groupLoadStarted else { return nil }
                groupLoadStarted = true
                defer { groupLoadWaiter = nil }
                return groupLoadWaiter
            }
            waiter?.resume()
            releaseGate.wait()
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

@MainActor @Test func successfulPositionSaveWinsOverStaleRowAndOfflineCacheUntilFreshList() async throws {
    let api = FakeAPI()
    let stale = makeVideo(id: 7, groupID: nil, plexKind: .movies, resumeSecs: 10)
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
        plexKind: stale.plexKind
    ) == .ask(secs: 120))

    api.videosError = URLError(.notConnectedToInternet)
    let videoStore = VideoStore(api: api, cache: cache, positionStore: positions, defaults: defaults)
    await videoStore.load()
    let cached = try #require(videoStore.videos.first)
    #expect(ResumeDecision.decide(
        resumeSecs: positions.resolved(server: cached.resumeSecs, for: cached.id),
        plexKind: cached.plexKind
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

@Test func videoDecodesVersionsAndDefaultsMissingVersions() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let data = Data("""
    {
      "id": 7,
      "url": "",
      "title": "A",
      "platform": null,
      "source_key": null,
      "preview_url": null,
      "group_id": null,
      "plex_kind": "movies",
      "position": 1,
      "status": "done",
      "error_msg": null,
      "stream_path": "/videos/7/stream",
      "source": "library",
      "chosen_version_id": 20,
      "versions": [
        {"id": 20, "label": "1080p", "status": "done", "is_chosen": true},
        {"id": 21, "label": "4K", "status": "unconverted", "is_chosen": false}
      ]
    }
    """.utf8)

    let video = try decoder.decode(Video.self, from: data)
    #expect(video.chosenVersionId == 20)
    #expect(video.versions == [
        VideoVersion(id: 20, label: "1080p", status: "done", isChosen: true),
        VideoVersion(id: 21, label: "4K", status: "unconverted", isChosen: false),
    ])

    let legacy = Data("""
    {
      "id": 1,
      "url": "u",
      "title": null,
      "platform": null,
      "source_key": null,
      "preview_url": null,
      "group_id": 1,
      "plex_kind": null,
      "position": 1,
      "status": "done",
      "error_msg": null,
      "stream_path": "/videos/1/stream",
      "source": null
    }
    """.utf8)
    let oldVideo = try decoder.decode(Video.self, from: legacy)
    #expect(oldVideo.chosenVersionId == nil)
    #expect(oldVideo.versions.isEmpty)
}

@Test func cacheLocalURLUsesVersionIdWhenPresent() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = CacheManager(root: root)

    #expect(cache.localURL(for: 7).lastPathComponent == "7.mp4")
    #expect(cache.localURL(for: 7, versionId: 20).lastPathComponent == "7.v20.mp4")
}

@MainActor @Test func loadPopulatesVideos() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api)
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
    let store = VideoStore(api: api)
    await store.load()
    await store.setGroup(id: 1, groupID: 2)
    #expect(store.errorText == nil)
    #expect(store.videos[0].groupID == 1)
}

@MainActor @Test func setGroupIgnoresPlexVideos() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, groupID: nil, plexKind: .movies)]
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.setGroup(id: 1, groupID: 2)

    #expect(api.setGroupRequests.isEmpty)
    #expect(store.videos[0].groupID == nil)
    #expect(store.videos[0].plexKind == .movies)
}

@MainActor @Test func setGroupSetsErrorOnThrow() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    api.throwOnSetGroup = true
    let store = VideoStore(api: api)
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

@MainActor @Test func olderGroupMoveInAnotherFeedDoesNotEvictTheNewerSameVideo() async {
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

    await gate.release(2)
    await older

    #expect(store.videos.map(\.id) == [1])
    #expect(cache.load(feed: .group(id: 1))?.map(\.id) == [1])

    await gate.release(3)
    await newer
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
    let store = VideoStore(api: api, cache: cache, defaults: makeDefaults())
    await store.load()

    async let older: Void = store.setGroup(id: 1, groupID: 2)
    await gate.waitForArrival(2)
    async let newer: Void = store.setGroup(id: 1, groupID: 3)
    await gate.waitForArrival(3)
    await gate.release(3)
    await newer

    #expect(cache.load(feed: .all)?.first?.groupID == 3)

    await gate.release(2)
    await older
    #expect(cache.load(feed: .all)?.first?.groupID == 3)
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

@MainActor @Test func owningMovePersistsWhileAnotherVideoIsPending() async {
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

    await gate.release(2)
    await pending
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
}

@MainActor @Test func chooseVersionOptimisticallyUpdatesThenKeepsOnSuccess() async throws {
    let versions = [
        VideoVersion(id: 10, label: "1080p", status: "done", isChosen: true),
        VideoVersion(id: 11, label: "4K", status: "unconverted", isChosen: false),
    ]
    let api = FakeAPI()
    api.videosToReturn = [
        makeVideo(id: 1, groupID: nil, plexKind: .movies, chosenVersionId: 10, versions: versions)
    ]
    let defaultsSuite = "VideoStoreTests.chooseVersionOptimisticallyUpdatesThenKeepsOnSuccess"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = VideoStore(api: api, defaults: defaults)
    await store.load()
    _ = try #require(store.videos.first)

    await store.chooseVersion(id: 1, versionId: 11)

    #expect(api.chosenVersions.count == 1)
    let chosenVersion = try #require(api.chosenVersions.first)
    #expect(chosenVersion.id == 1)
    #expect(chosenVersion.versionId == 11)
    #expect(store.videos[0].chosenVersionId == 11)
    #expect(store.videos[0].status == "unconverted")
    #expect(store.videos[0].versions.map(\.isChosen) == [false, true])
}

@MainActor @Test func chooseVersionRevertsOnFailure() async throws {
    let versions = [
        VideoVersion(id: 10, label: "1080p", status: "done", isChosen: true),
        VideoVersion(id: 11, label: "4K", status: "unconverted", isChosen: false),
    ]
    let api = FakeAPI()
    api.videosToReturn = [
        makeVideo(id: 1, groupID: nil, plexKind: .movies, chosenVersionId: 10, versions: versions)
    ]
    api.chooseVersionResult = false
    let defaultsSuite = "VideoStoreTests.chooseVersionRevertsOnFailure"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = VideoStore(api: api, defaults: defaults)
    await store.load()
    _ = try #require(store.videos.first)

    await store.chooseVersion(id: 1, versionId: 11)

    #expect(store.videos[0].chosenVersionId == 10)
    #expect(store.videos[0].versions.map(\.isChosen) == [true, false])
}

@MainActor @Test func chooseAudioOptimisticallyUpdatesThenReloads() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.load()

    await store.chooseAudio(id: 1, lang: "es")

    #expect(api.chosenAudio.map(\.id) == [1])
    #expect(api.chosenAudio.map(\.lang) == ["es"])
    #expect(api.loadCount == 2)
}

@MainActor @Test func chooseAudioRevertsWhenServerReturnsNotOk() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1)]
    api.chooseAudioResult = false
    let store = VideoStore(api: api)
    await store.load()

    await store.chooseAudio(id: 1, lang: "es")

    #expect(store.videos[0].audioLang == nil)
    #expect(api.loadCount == 1)
}

private func tempCache() -> VideoListCache {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vlc-\(UUID().uuidString)")
    return VideoListCache(root: dir)
}

@MainActor @Test func loadSavesResponseToCache() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let cache = tempCache()
    let store = VideoStore(api: api, cache: cache)
    await store.load()
    #expect(cache.load(feed: .all)?.count == 2)
}

@MainActor @Test func loadFallsBackToCacheAndSetsErrorWhenNetworkFails() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache)
    await store.load()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText?.contains("503") == true)
}

@MainActor @Test func loadSetsErrorWhenNetworkFailsAndNoCache() async {
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: tempCache())
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
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    #expect(store.errorText == nil)
}

@MainActor @Test func loadIgnoresNSURLCancellation() async {
    let api = FakeAPI()
    api.videosError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    #expect(store.errorText == nil)
}

@MainActor @Test func loadIgnoresTaskCancellation() async {
    let api = FakeAPI()
    api.videosError = CancellationError()
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    #expect(store.errorText == nil)
}

// A cancelled refresh must not wipe out what is already on screen.
@MainActor @Test func loadKeepsExistingVideosOnCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: tempCache())
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
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    api.mutationError = URLError(.cancelled)
    await store.setGroup(id: 1, groupID: 2)
    #expect(store.errorText == nil)
    #expect(store.videos.first?.groupID == 1)
}

@MainActor @Test func chooseVersionIgnoresCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    api.mutationError = CancellationError()
    await store.chooseVersion(id: 1, versionId: 7)
    #expect(store.errorText == nil)
}

@MainActor @Test func chooseAudioIgnoresCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    api.mutationError = URLError(.cancelled)
    await store.chooseAudio(id: 1, lang: "spa")
    #expect(store.errorText == nil)
}

@MainActor @Test func deleteIgnoresCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache())
    api.mutationError = URLError(.cancelled)
    await store.delete(id: 1)
    #expect(store.errorText == nil)
}

@MainActor @Test func uploadIgnoresCancellation() async {
    let api = FakeAPI()
    let store = VideoStore(api: api, cache: tempCache())
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

@MainActor @Test func refreshLibraryIgnoresScanCancellation() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api, cache: tempCache())
    api.scanError = URLError(.cancelled)
    await store.refreshLibrary()
    #expect(store.errorText == nil)
    #expect(store.videos.map(\.id) == [1])   // load() still ran
}

// A genuine scan failure must still surface -- the cancellation guard is
// narrow, not a blanket silencer.
@MainActor @Test func refreshLibraryStillReportsRealScanFailure() async {
    let api = FakeAPI(); api.throwOnScan = true
    let store = VideoStore(api: api, cache: tempCache())
    await store.refreshLibrary()
    #expect(store.errorText?.contains("500") == true)
}

@MainActor @Test func bootLoadShowsCacheThenRefreshes() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: cache)
    await store.bootLoad()
    #expect(api.loadCount == 1)               // did hit network to refresh
    #expect(store.videos.map(\.id) == [1, 2]) // ended on fresh data
}

@MainActor @Test func bootLoadServesCacheAndSetsErrorOffline() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], feed: .all)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache)
    await store.bootLoad()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText?.contains("503") == true)
}

@MainActor @Test func deleteCallsApiThenRefetches() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.load()          // loadCount == 1
    await store.delete(id: 1)   // delete -> reload
    #expect(api.deletedIds == [1])
    #expect(api.loadCount == 2)
}

@MainActor @Test func refreshLibraryScansThenReloads() async {
    let api = FakeAPI()
    api.scanResult = ScanResult(added: 2, updated: 0, skipped: 1)
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.refreshLibrary()
    #expect(api.scanCalls == 1)
    #expect(store.videos.map(\.id) == [1])
}

@MainActor @Test func refreshLibraryToleratesScanFailureButStillReloads() async {
    // A scan failure must not prevent the subsequent list reload from running:
    // the video list still ends up fresh even though the scan call itself errored.
    let api = FakeAPI()
    api.throwOnScan = true
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.refreshLibrary()
    #expect(api.scanCalls == 1)
    #expect(api.loadCount == 1)
    #expect(store.videos.map(\.id) == [1])
}

@MainActor @Test func refreshLibraryPreservesScanErrorWhenLoadSucceeds() async {
    // scanLibrary() fails, but the subsequent load() fetch succeeds -- the scan
    // failure message must still surface in errorText rather than being wiped
    // out by load()'s unconditional `errorText = nil` reset.
    let api = FakeAPI()
    api.throwOnScan = true
    api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.refreshLibrary()
    #expect(store.videos.map(\.id) == [1])
    #expect(store.errorText != nil)
    #expect(store.errorText?.contains("500") == true)
}

@MainActor @Test func refreshLibraryLoadErrorTakesPrecedenceOverScanSuccess() async {
    // scanLibrary() succeeds but the subsequent load() fetch fails -- errorText
    // should reflect the load failure, not stale state from the (successful) scan.
    let api = FakeAPI()
    api.throwOnScan = false
    api.throwOnVideos = true
    let store = VideoStore(api: api)
    await store.refreshLibrary()
    #expect(store.errorText != nil)
    #expect(store.errorText?.contains("503") == true)
}

@MainActor @Test func ensureReadyPollsUntilDone() async throws {
    let api = FakeAPI()
    api.prepareResult = "converting"
    api.videoResults = [
        makeVideo(id: 7, status: "converting"),
        makeVideo(id: 7, status: "converting"),
        makeVideo(id: 7, status: "done"),
    ]
    let store = VideoStore(api: api)
    let ready = try await store.ensureReady(id: 7, pollIntervalSeconds: 0.01)
    #expect(ready.status == "done")
    #expect(api.videoCalls == 3)
}

@MainActor @Test func ensureReadyShortCircuitsWhenAlreadyDoneAfterPrepare() async throws {
    let api = FakeAPI()
    api.prepareResult = "done"
    api.videoResults = [makeVideo(id: 7, status: "done")]
    let store = VideoStore(api: api)
    let ready = try await store.ensureReady(id: 7, pollIntervalSeconds: 0.01)
    #expect(ready.status == "done")
    #expect(api.videoCalls == 1)
}

@MainActor @Test func ensureReadyThrowsOnConversionError() async {
    let api = FakeAPI()
    api.prepareResult = "converting"
    api.videoResults = [
        makeVideo(id: 7, status: "unconverted", errorMsg: "ffmpeg exploded"),
    ]
    let store = VideoStore(api: api)
    do {
        _ = try await store.ensureReady(id: 7, pollIntervalSeconds: 0.01)
        Issue.record("expected throw")
    } catch let error as PrepareError {
        #expect(error == .conversionFailed("ffmpeg exploded"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@MainActor @Test func clearListCacheEmptiesVideosAndDiskCache() async {
    let cache = tempCache()
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: cache)
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
    let store = VideoStore(api: api, cache: cache)

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
    let store = VideoStore(api: api, cache: tempCache())

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
    let store = VideoStore(api: api, cache: cache)

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
