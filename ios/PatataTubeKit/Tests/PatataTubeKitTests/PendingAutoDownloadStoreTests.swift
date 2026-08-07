import XCTest
@testable import PatataTubeKit

final class PendingAutoDownloadStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PendingAutoDownloadStoreTests-\(UUID().uuidString)")!
    }

    func testStartsEmpty() {
        XCTAssertEqual(PendingAutoDownloadStore(defaults: makeDefaults()).ids, [])
    }

    func testAddPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = PendingAutoDownloadStore(defaults: defaults)
        store.add(7)
        store.add(9)
        XCTAssertEqual(store.ids, [7, 9])
        XCTAssertEqual(PendingAutoDownloadStore(defaults: defaults).ids, [7, 9])
    }

    func testRemoveIsPersistedAndIdempotent() {
        let defaults = makeDefaults()
        let store = PendingAutoDownloadStore(defaults: defaults)
        store.add(7)
        store.remove(7)
        store.remove(7)
        XCTAssertEqual(store.ids, [])
        XCTAssertEqual(PendingAutoDownloadStore(defaults: defaults).ids, [])
    }

    func testContains() {
        let store = PendingAutoDownloadStore(defaults: makeDefaults())
        store.add(3)
        XCTAssertTrue(store.contains(3))
        XCTAssertFalse(store.contains(4))
    }

    func testSurvivesACorruptMirror() {
        let defaults = makeDefaults()
        defaults.set("not ids", forKey: PendingAutoDownloadStore.defaultsKey)
        XCTAssertEqual(PendingAutoDownloadStore(defaults: defaults).ids, [])
    }

    /// The set is a work list, not a history: an unbounded one would keep
    /// retrying videos whose conversion died months ago.
    func testAddEvictsOldestBeyondTheCap() {
        let store = PendingAutoDownloadStore(defaults: makeDefaults())
        for id in 1...(PendingAutoDownloadStore.capacity + 3) { store.add(id) }
        XCTAssertEqual(store.ids.count, PendingAutoDownloadStore.capacity)
        XCTAssertFalse(store.contains(1))
        XCTAssertTrue(store.contains(PendingAutoDownloadStore.capacity + 3))
    }
}
