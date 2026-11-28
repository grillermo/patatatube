import XCTest
@testable import PatataTubeKit

final class AutoDownloadStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AutoDownloadStoreTests-\(UUID().uuidString)")!
    }

    private func video(_ id: Int, status: String = "done", stream: String = "/videos/1/stream") -> Video {
        Video(id: id, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
              groupID: 1, position: nil, status: status, errorMsg: nil, streamPath: stream)
    }

    func testSetPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = AutoDownloadStore(defaults: defaults)
        store.set(3, true)
        store.set(5, true)
        store.set(3, false)
        XCTAssertEqual(AutoDownloadStore(defaults: defaults).groupIDs, [5])
    }

    func testRetainDropsDeletedGroups() {
        let defaults = makeDefaults()
        let store = AutoDownloadStore(defaults: defaults)
        store.set(1, true)
        store.set(2, true)
        store.retain(only: [2, 9])
        XCTAssertEqual(AutoDownloadStore(defaults: defaults).groupIDs, [2])
    }

    func testTargetsSkipUnfinishedStreamlessAndAlreadyCached() {
        let videos = [
            video(1),
            video(2, status: "downloading"),
            video(3, stream: ""),
            video(4),
            video(5),
        ]
        let states: [Int: CacheState] = [4: .cached, 5: .downloading(0.3)]
        let picked = AutoDownloadStore.targets(in: videos) { states[$0.id] ?? .notCached }
        XCTAssertEqual(picked.map(\.id), [1])
    }
}
