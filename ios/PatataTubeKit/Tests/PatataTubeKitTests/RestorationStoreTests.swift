import XCTest
@testable import PatataTubeKit

final class RestorationStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "restoration.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLoadWithNothingStoredReturnsEmpty() {
        let store = RestorationStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), RestorationState.empty)
    }

    func testRoundTripsEveryField() {
        let defaults = makeDefaults()
        var state = RestorationState.empty
        state.feed = .group(id: 3)
        state.path = [.group(id: 3), .downloads]
        state.search = "bear"
        state.scrollAnchors = [
            RestorationState.gridKey(feed: .group(id: 3)): "12",
        ]
        state.player = PlayerState(videoID: 42, versionID: 7, sleepMode: true)

        RestorationStore(defaults: defaults).save(state)

        // A fresh instance reads what the first one wrote.
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), state)
    }

    func testCorruptStorageLoadsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: RestorationStore.storageKey)

        let store = RestorationStore(defaults: defaults)
        XCTAssertEqual(store.load(), RestorationState.empty)

        // And is overwritten by the next save rather than blocking it.
        var state = RestorationState.empty
        state.search = "kids"
        store.save(state)
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), state)
    }

    func testMutateAppliesToStoredState() {
        let defaults = makeDefaults()
        let store = RestorationStore(defaults: defaults)
        store.mutate { $0.path = [.downloads] }
        store.mutate { $0.search = "abc" }

        let loaded = RestorationStore(defaults: defaults).load()
        XCTAssertEqual(loaded.path, [.downloads])
        XCTAssertEqual(loaded.search, "abc")
    }

    func testScreenKeysAreDistinct() {
        XCTAssertNotEqual(RestorationState.gridKey(feed: .group(id: 3)),
                          RestorationState.gridKey(feed: .group(id: 4)))
        XCTAssertNotEqual(RestorationState.gridKey(feed: .all),
                          RestorationState.gridKey(feed: .group(id: 4)))
    }

    func testLegacyShowRouteFallsBackToDefaultState() {
        let defaults = makeDefaults()
        // A blob written by a build that still had the TV tab.
        let legacy = #"{"feed":null,"path":[{"show":{"title":"Bluey"}}],"search":"","scrollAnchors":{},"tab":"tv"}"#
        defaults.set(Data(legacy.utf8), forKey: RestorationStore.storageKey)
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), RestorationState.empty)
    }

    func testLegacyTabKeyIsIgnored() {
        let defaults = makeDefaults()
        let legacy = #"{"feed":{"group":{"id":3}},"path":[{"group":{"id":3}}],"search":"","scrollAnchors":{},"tab":"videos"}"#
        defaults.set(Data(legacy.utf8), forKey: RestorationStore.storageKey)
        XCTAssertEqual(RestorationStore(defaults: defaults).load().path, [.group(id: 3)])
    }

    func testBlobWithoutTabStillDecodes() {
        let defaults = makeDefaults()
        let legacy = """
        {"path":[],"search":"","scrollAnchors":{}}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: RestorationStore.storageKey)
        let loaded = RestorationStore(defaults: defaults).load()
        XCTAssertNil(loaded.feed)
    }
}
