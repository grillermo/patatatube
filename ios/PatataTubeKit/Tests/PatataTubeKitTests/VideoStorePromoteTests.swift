import Testing
import Foundation
@testable import PatataTubeKit

private func makeDefaults() -> UserDefaults {
    let suite = "video-store-promote.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private final class SpyMediaCache: MediaCaching, @unchecked Sendable {
    private(set) var purged: [Int] = []
    func removeAllCached(id: Int) { purged.append(id) }
}

private final class PromoteAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var promoteResult = true

    func videos(feed: Feed) async throws -> [Video] { videosToReturn }
    func promote(id: Int, kind: PlexKind) async throws -> Bool {
        // Mirror the real server: a promotion hard-deletes the row, so it's gone
        // from any subsequent videos() fetch (e.g. VideoStore's post-promote reload).
        if promoteResult {
            videosToReturn.removeAll { $0.id == id }
        }
        return promoteResult
    }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func savePosition(id: Int, secs: Double) async throws {}
    func upload(url: String, groupID: Int?) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { videosToReturn[0] }
    func imageData(path: String) async throws -> Data { Data() }
    func jobs() async throws -> JobsSnapshot { .empty }
}

private func video(_ id: Int) -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, groupID: 1, plexKind: nil, position: id,
          status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream",
          chosenVersionId: nil, versions: [])
}

@MainActor @Test func promoteRemovesAPromotedVideoFromTheList() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1), video(2)]
    api.promoteResult = true
    let store = VideoStore(api: api, defaults: makeDefaults())
    await store.load()

    await store.promote(id: 1, kind: .movies)

    #expect(store.videos.map(\.id) == [2])
    #expect(store.errorText == nil)
}

@MainActor @Test func promotePurgesTheCachedFileOfAPromotedVideo() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.promoteResult = true
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy, defaults: makeDefaults())
    await store.load()

    await store.promote(id: 1, kind: .movies)

    #expect(spy.purged == [1])
}

@MainActor @Test func promoteKeepsTheVideoWhenNotPromoted() async {
    let api = PromoteAPI(); api.videosToReturn = [video(1)]
    api.promoteResult = false
    let spy = SpyMediaCache()
    let store = VideoStore(api: api, mediaCache: spy, defaults: makeDefaults())
    await store.load()

    await store.promote(id: 1, kind: .movies)

    #expect(store.videos.map(\.id) == [1])
    #expect(store.videos[0].groupID == 1)
    #expect(spy.purged.isEmpty)
}
