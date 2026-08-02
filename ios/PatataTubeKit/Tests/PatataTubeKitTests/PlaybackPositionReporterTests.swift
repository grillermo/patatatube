import XCTest
@testable import PatataTubeKit

/// Records savePosition calls; every other VideoAPI member is unused here.
private final class SpyAPI: VideoAPI, @unchecked Sendable {
    var saved: [(id: Int, secs: Double)] = []
    var failNext = false
    let lock = NSLock()

    func savePosition(id: Int, secs: Double) async throws {
        try lock.withLock {
            if failNext {
                failNext = false
                throw APIError.badStatus(500)
            }
            saved.append((id, secs))
        }
    }

    func videos(classification: String?) async throws -> [Video] { [] }
    func classifications() async throws -> [String] { [] }
    func classify(id: Int, classification: String) async throws -> ClassifyResult { ClassifyResult(ok: true) }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { throw APIError.notConfigured }
    func imageData(path: String) async throws -> Data { Data() }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

final class PlaybackPositionReporterTests: XCTestCase {
    private func makeStore() throws -> ResumePositionStore {
        ResumePositionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "reporter-\(UUID().uuidString)")))
    }

    func testFirstRecordWritesThrough() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.local(for: 5), 30)
    }

    func testSecondRecordInsideIntervalIsLocalOnly() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock.now() })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock.set(Date(timeIntervalSince1970: 4))
        await reporter.record(id: 5, secs: 34, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.local(for: 5), 34)
    }

    func testRecordAfterIntervalWritesThrough() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock.now() })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock.set(Date(timeIntervalSince1970: 11))
        await reporter.record(id: 5, secs: 41, duration: 1000, force: false)
        XCTAssertEqual(api.saved.map(\.secs), [30, 41])
    }

    func testForceWritesThroughInsideInterval() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock.now() })
        await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        clock.set(Date(timeIntervalSince1970: 1))
        await reporter.record(id: 5, secs: 31, duration: 1000, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [30, 31])
    }

    func testNearEndClearsToZero() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 980, duration: 1000, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [0])
        XCTAssertEqual(store.local(for: 5), 0)
    }

    func testUnknownDurationDoesNotClear() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 980, duration: nil, force: true)
        XCTAssertEqual(api.saved.map(\.secs), [980])
    }

    func testFailedWriteStaysPending() async throws {
        let api = SpyAPI()
        api.failNext = true
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        XCTAssertEqual(api.saved.count, 0)
        XCTAssertEqual(store.pending(), [5: 30])
    }

    func testFlushPendingResendsAndClears() async throws {
        let api = SpyAPI()
        api.failNext = true
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        await reporter.flushPending()
        XCTAssertEqual(api.saved.map(\.secs), [30])
        XCTAssertEqual(store.pending(), [:])
    }

    func testSuccessfulWriteClearsPending() async throws {
        let api = SpyAPI()
        let store = try makeStore()
        let reporter = PlaybackPositionReporter(api: api, store: store)
        await reporter.record(id: 5, secs: 30, duration: 1000, force: true)
        XCTAssertEqual(store.pending(), [:])
    }
}
