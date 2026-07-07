import Testing
import Foundation
@testable import PatataTubeKit

private func makeVideo(id: Int, classification: String = "children", status: String = "completed",
                        errorMsg: String? = nil) -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, classification: classification, position: id,
          status: status, errorMsg: errorMsg, streamPath: "/videos/\(id)/stream")
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
    var scanResult = ScanResult(added: 0, updated: 0, skipped: 0)
    var throwOnScan = false
    private(set) var scanCalls = 0
    var prepareResult = "done"
    var videoResults: [Video] = []
    private(set) var videoCalls = 0

    func scanLibrary() async throws -> ScanResult {
        scanCalls += 1
        if throwOnScan { throw APIError.badStatus(500) }
        return scanResult
    }
    func prepare(id: Int) async throws -> String { prepareResult }
    func video(id: Int) async throws -> Video {
        videoCalls += 1
        return videoResults.isEmpty ? makeVideo(id: id) : videoResults[min(videoCalls, videoResults.count) - 1]
    }
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
