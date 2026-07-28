import Testing
import Foundation
@testable import PatataTubeKit

private final class SpyMediaCache: MediaCaching, @unchecked Sendable {
    private(set) var purged: [Int] = []
    func removeAllCached(id: Int) { purged.append(id) }
}

private final class PromoteAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var classifyResult = ClassifyResult(ok: true, promoted: true)

    func videos(classification: String?) async throws -> [Video] { videosToReturn }
    func classifications() async throws -> [String] { ["children", "movies"] }
    func classify(id: Int, classification: String) async throws -> ClassifyResult { classifyResult }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { videosToReturn[0] }
    func imageData(path: String) async throws -> Data { Data() }
}

private func video(_ id: Int) -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, classification: "children", position: id,
          status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream",
          chosenVersionId: nil, versions: [])
}

@MainActor @Test func classifyRemovesAPromotedVideoFromTheList() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1), video(2)]
    api.classifyResult = ClassifyResult(ok: true, promoted: true)
    let store = VideoStore(api: api)
    await store.load()

    await store.classify(id: 1, to: "movies")

    #expect(store.videos.map(\.id) == [2])
    #expect(store.errorText == nil)
}

@MainActor @Test func classifyPurgesTheCachedFileOfAPromotedVideo() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.classifyResult = ClassifyResult(ok: true, promoted: true)
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy)
    await store.load()

    await store.classify(id: 1, to: "movies")

    #expect(spy.purged == [1])
}

@MainActor @Test func classifyKeepsTheVideoWhenNotPromoted() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.classifyResult = ClassifyResult(ok: true, promoted: false)
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy)
    await store.load()

    await store.classify(id: 1, to: "adults")

    #expect(store.videos.map(\.id) == [1])
    #expect(store.videos[0].classification == "adults")
    #expect(spy.purged.isEmpty)
}
