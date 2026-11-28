import XCTest
@testable import PatataTubeKit

final class DeviceGroupFlagsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DeviceGroupFlagsTests-\(UUID().uuidString)")!
    }

    private func video(_ id: Int, status: String = "done", stream: String = "/videos/1/stream") -> Video {
        Video(id: id, url: "u", title: nil, platform: nil, sourceKey: nil, previewUrl: nil,
              groupID: 1, position: nil, status: status, errorMsg: nil, streamPath: stream)
    }

    func testSetPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = DeviceGroupFlags(key: "k", defaults: defaults)
        store.set(3, true)
        store.set(5, true)
        store.set(3, false)
        XCTAssertEqual(DeviceGroupFlags(key: "k", defaults: defaults).groupIDs, [5])
    }

    func testKeysAreIndependent() {
        let defaults = makeDefaults()
        DeviceGroupFlags(key: DeviceGroupFlags.autoDownloadDefaultsKey, defaults: defaults).set(1, true)
        XCTAssertEqual(DeviceGroupFlags(key: DeviceGroupFlags.autoPlayDefaultsKey, defaults: defaults).groupIDs, [])
    }

    func testRetainDropsDeletedGroups() {
        let defaults = makeDefaults()
        let store = DeviceGroupFlags(key: "k", defaults: defaults)
        store.set(1, true)
        store.set(2, true)
        store.retain(only: [2, 9])
        XCTAssertEqual(DeviceGroupFlags(key: "k", defaults: defaults).groupIDs, [2])
    }

    func testTargetsSkipUnfinishedStreamlessAndAlreadyCached() {
        let videos = [video(1), video(2, status: "downloading"), video(3, stream: ""), video(4), video(5)]
        let states: [Int: CacheState] = [4: .cached, 5: .downloading(0.3)]
        let picked = AutoDownload.targets(in: videos) { states[$0.id] ?? .notCached }
        XCTAssertEqual(picked.map(\.id), [1])
    }

    func testReadyToAutoPlay() {
        let mb: Int64 = 1024 * 1024
        XCTAssertTrue(AutoDownload.readyToAutoPlay(state: .cached, transferred: 0, total: nil))
        XCTAssertFalse(AutoDownload.readyToAutoPlay(state: .notCached, transferred: 10 * mb, total: nil))
        XCTAssertFalse(AutoDownload.readyToAutoPlay(state: .downloading(0.01), transferred: 1 * mb, total: 100 * mb))
        XCTAssertTrue(AutoDownload.readyToAutoPlay(state: .downloading(0.04), transferred: 4 * mb, total: 100 * mb))
        XCTAssertTrue(AutoDownload.readyToAutoPlay(state: .downloading(1), transferred: 2 * mb, total: 2 * mb))
    }
}
