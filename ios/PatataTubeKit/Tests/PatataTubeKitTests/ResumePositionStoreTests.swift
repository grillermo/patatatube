import XCTest
@testable import PatataTubeKit

final class ResumePositionStoreTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "resume-tests-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testSetLocalRoundTrips() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        XCTAssertEqual(store.local(for: 7), 91.5)
    }

    func testLocalIsNilWhenUnset() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        XCTAssertNil(store.local(for: 7))
    }

    func testSetLocalMarksPending() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        XCTAssertEqual(store.pending(), [7: 91.5])
    }

    func testMarkSyncedClearsPendingButKeepsValue() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(91.5, for: 7)
        store.markSynced(id: 7)
        XCTAssertEqual(store.pending(), [:])
        XCTAssertEqual(store.local(for: 7), 91.5)
    }

    func testResolvedPrefersPendingLocalOverServer() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)
        XCTAssertEqual(store.resolved(server: 10, for: 7), 300)
    }

    func testResolvedPrefersSyncedLocalUntilFreshServerList() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)
        store.markSynced(id: 7)
        XCTAssertEqual(store.resolved(server: 10, for: 7), 300)
    }

    func testFreshServerListReplacesSyncedLocalValue() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)
        store.markSynced(id: 7)

        store.reconcileFreshServerPositions([7: 10])

        XCTAssertEqual(store.resolved(server: 10, for: 7), 10)
    }

    func testFreshServerListDoesNotReplacePendingLocalValue() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(300, for: 7)

        store.reconcileFreshServerPositions([7: 10])

        XCTAssertEqual(store.resolved(server: 10, for: 7), 300)
    }

    func testResolvedFallsBackToServerWithoutLocal() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        XCTAssertEqual(store.resolved(server: 42, for: 7), 42)
    }

    func testZeroIsStoredNotTreatedAsMissing() throws {
        let store = ResumePositionStore(defaults: try makeDefaults())
        store.setLocal(0, for: 7)
        XCTAssertEqual(store.local(for: 7), 0)
        XCTAssertEqual(store.resolved(server: 500, for: 7), 0)
    }

    func testPendingPositionsAreNamespacedByNormalizedServer() throws {
        let defaults = try makeDefaults()
        let store = ResumePositionStore(
            defaults: defaults,
            serverURL: URL(string: "HTTPS://Example.COM:443/api/")
        )
        store.setLocal(91.5, for: 7)

        store.useServer(URL(string: "https://other.example/api"))
        XCTAssertNil(store.local(for: 7))
        XCTAssertEqual(store.pending(), [:])

        store.useServer(URL(string: "https://example.com/api"))
        XCTAssertEqual(store.local(for: 7), 91.5)
        XCTAssertEqual(store.pending(), [7: 91.5])
    }
}
