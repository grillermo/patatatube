import XCTest
@testable import PatataTubeKit

final class GroupPosterStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "groupposter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func video(id: Int, preview: String?) -> Video {
        Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
              previewUrl: preview, classification: "children", position: id,
              status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream")
    }

    func testUnknownGroupHasNoPoster() {
        let store = GroupPosterStore(defaults: makeDefaults())
        XCTAssertNil(store.poster(for: "asmr"))
    }

    func testRecordsFirstVideoWithAPreview() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 1, preview: nil), video(id: 2, preview: "/videos/2/preview")],
                     for: "children")
        XCTAssertEqual(store.poster(for: "children"),
                       GroupPoster(videoID: 2, path: "/videos/2/preview"))
    }

    func testEmptyListLeavesThePreviousPosterAlone() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 2, preview: "/videos/2/preview")], for: "children")
        store.record([], for: "children")
        XCTAssertEqual(store.poster(for: "children")?.videoID, 2)
    }

    func testIgnoresNonGroupFilters() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 3, preview: "/videos/3/preview")], for: "tv")
        store.record([video(id: 4, preview: "/videos/4/preview")], for: nil)
        XCTAssertNil(store.poster(for: "tv"))
    }

    func testGroupsGetSeparateKeys() {
        XCTAssertNotEqual(GroupPosterStore.key("children"), GroupPosterStore.key("adults"))
    }
}
