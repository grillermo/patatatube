import Testing
import Foundation
@testable import PatataTubeKit

private func makeVideo(id: Int, classification: String = "children") -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, classification: classification, position: id,
          status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream")
}

private final class FakeAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var classifyResult = true
    var moveResult = true
    var uploadId = 100
    var throwOnClassify = false
    var throwOnVideos = false
    private(set) var loadCount = 0

    func videos(classification: String?) async throws -> [Video] {
        loadCount += 1
        if throwOnVideos { throw APIError.badStatus(503) }
        if let c = classification { return videosToReturn.filter { $0.classification == c } }
        return videosToReturn
    }
    func classifications() async throws -> [String] { ["children", "adults"] }
    func move(id: Int, direction: String) async throws -> Bool { moveResult }
    func classify(id: Int, classification: String) async throws -> Bool {
        if throwOnClassify { throw APIError.badStatus(500) }
        return classifyResult
    }
    func upload(url: String) async throws -> Int { uploadId }
    var deleteResult = true
    private(set) var deletedIds: [Int] = []
    func delete(id: Int) async throws -> Bool {
        deletedIds.append(id)
        return deleteResult
    }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { makeVideo(id: id) }
    func imageData(path: String) async throws -> Data { Data() }
}

@MainActor @Test func loadPopulatesVideos() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api)
    await store.load()
    #expect(store.videos.count == 2)
    #expect(store.isLoading == false)
    #expect(store.errorText == nil)
}

@MainActor @Test func classifyOptimisticallyUpdatesThenKeepsOnSuccess() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.classifyResult = true
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "adults")
}

@MainActor @Test func classifyRevertsWhenServerReturnsNotOk() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.classifyResult = false
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "children")
}

@MainActor @Test func classifyRevertsAndSetsErrorOnThrow() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.throwOnClassify = true
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "children")
    #expect(store.errorText != nil)
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
    #expect(cache.load(classification: nil)?.count == 2)
}

@MainActor @Test func loadFallsBackToCacheWhenNetworkFails() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], classification: nil)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache)
    await store.load()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText == nil)
}

@MainActor @Test func loadSetsErrorWhenNetworkFailsAndNoCache() async {
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: tempCache())
    await store.load()
    #expect(store.videos.isEmpty)
    #expect(store.errorText != nil)
}

@MainActor @Test func bootLoadShowsCacheThenRefreshes() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], classification: nil)
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api, cache: cache)
    await store.bootLoad()
    #expect(api.loadCount == 1)               // did hit network to refresh
    #expect(store.videos.map(\.id) == [1, 2]) // ended on fresh data
}

@MainActor @Test func bootLoadServesCacheOffline() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9)], classification: nil)
    let api = FakeAPI(); api.throwOnVideos = true
    let store = VideoStore(api: api, cache: cache)
    await store.bootLoad()
    #expect(store.videos.map(\.id) == [9])
    #expect(store.errorText == nil)
}

@MainActor @Test func deleteCallsApiThenRefetches() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.load()          // loadCount == 1
    await store.delete(id: 1)   // delete -> reload
    #expect(api.deletedIds == [1])
    #expect(api.loadCount == 2)
}

@MainActor @Test func moveRefetchesOnSuccess() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.load()          // loadCount == 1
    await store.move(id: 1, direction: "up")  // success -> reload
    #expect(api.loadCount == 2)
}
