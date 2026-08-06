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

    func videos(feed: Feed) async throws -> [Video] { [] }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String, groupID: Int?) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { throw APIError.notConfigured }
    func imageData(path: String) async throws -> Data { Data() }
    func jobs() async throws -> JobsSnapshot { .empty }
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

private final class ControlledSpyAPI: VideoAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldBlockNextSave = false
    private var blockedSave: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    var saved: [(id: Int, secs: Double)] = []

    func blockNextSave() {
        lock.withLock { shouldBlockNextSave = true }
    }

    func waitForBlockedSave() async {
        if lock.withLock({ blockedSave != nil }) { return }
        await withCheckedContinuation { continuation in
            let alreadyBlocked = lock.withLock { () -> Bool in
                if blockedSave != nil { return true }
                startedWaiter = continuation
                return false
            }
            if alreadyBlocked { continuation.resume() }
        }
    }

    func releaseBlockedSave() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { blockedSave = nil }
            return blockedSave
        }
        continuation?.resume()
    }

    func savePosition(id: Int, secs: Double) async throws {
        let shouldBlock = lock.withLock { () -> Bool in
            defer { shouldBlockNextSave = false }
            return shouldBlockNextSave
        }
        if shouldBlock {
            await withCheckedContinuation { continuation in
                let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    blockedSave = continuation
                    defer { startedWaiter = nil }
                    return startedWaiter
                }
                waiter?.resume()
            }
        }
        lock.withLock { saved.append((id, secs)) }
    }

    func videos(feed: Feed) async throws -> [Video] { [] }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String, groupID: Int?) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { throw APIError.notConfigured }
    func imageData(path: String) async throws -> Data { Data() }
    func jobs() async throws -> JobsSnapshot { .empty }
}

private final class DestinationControlledAPI: VideoAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var activeServerIdentity: String
    private var blockedSave: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var sentServerIdentities: [String] = []

    init(activeServerIdentity: String) {
        self.activeServerIdentity = activeServerIdentity
    }

    func setActiveServerIdentity(_ identity: String) {
        lock.withLock { activeServerIdentity = identity }
    }

    func waitForBlockedSave() async {
        if lock.withLock({ blockedSave != nil }) { return }
        await withCheckedContinuation { continuation in
            let alreadyBlocked = lock.withLock { () -> Bool in
                if blockedSave != nil { return true }
                startedWaiter = continuation
                return false
            }
            if alreadyBlocked { continuation.resume() }
        }
    }

    func releaseBlockedSave() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { blockedSave = nil }
            return blockedSave
        }
        continuation?.resume()
    }

    func savePosition(id: Int, secs: Double) async throws {
        try await controlledSave(destinationServerIdentity: nil)
    }

    func savePosition(
        id: Int, secs: Double, destinationServerIdentity: String
    ) async throws {
        try await controlledSave(destinationServerIdentity: destinationServerIdentity)
    }

    private func controlledSave(destinationServerIdentity: String?) async throws {
        await withCheckedContinuation { continuation in
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                blockedSave = continuation
                defer { startedWaiter = nil }
                return startedWaiter
            }
            waiter?.resume()
        }
        try lock.withLock {
            if let destinationServerIdentity,
               destinationServerIdentity != activeServerIdentity {
                throw APIError.badStatus(409)
            }
            sentServerIdentities.append(activeServerIdentity)
        }
    }

    func videos(feed: Feed) async throws -> [Video] { [] }
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool { true }
    func chooseAudio(id: Int, lang: String) async throws -> Bool { true }
    func upload(url: String, groupID: Int?) async throws -> Int { 0 }
    func delete(id: Int) async throws -> Bool { true }
    func scanLibrary() async throws -> ScanResult { ScanResult(added: 0, updated: 0, skipped: 0) }
    func prepare(id: Int, bulk: Bool) async throws -> String { "done" }
    func video(id: Int) async throws -> Video { throw APIError.notConfigured }
    func imageData(path: String) async throws -> Data { Data() }
    func jobs() async throws -> JobsSnapshot { .empty }
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

    func testFlushDoesNotSendAnotherServersPendingPosition() async throws {
        let api = SpyAPI()
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "reporter-server-\(UUID().uuidString)")
        )
        let store = ResumePositionStore(
            defaults: defaults,
            serverURL: URL(string: "https://server-a.test")
        )
        store.setLocal(30, for: 5)
        store.useServer(URL(string: "https://server-b.test"))
        let reporter = PlaybackPositionReporter(api: api, store: store)

        await reporter.flushPending()

        XCTAssertTrue(api.saved.isEmpty)
        store.useServer(URL(string: "https://server-a.test"))
        await reporter.flushPending()
        XCTAssertEqual(api.saved.map(\.secs), [30])
    }

    func testServerSwitchAfterFlushCaptureDoesNotSendToNewServer() async throws {
        let serverA = ResumePositionStore.normalizedServerIdentity(
            URL(string: "https://server-a.test")
        )
        let serverB = ResumePositionStore.normalizedServerIdentity(
            URL(string: "https://server-b.test")
        )
        let api = DestinationControlledAPI(activeServerIdentity: serverA)
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "reporter-server-race-\(UUID().uuidString)")
        )
        let store = ResumePositionStore(
            defaults: defaults,
            serverURL: URL(string: "https://server-a.test")
        )
        store.setLocal(30, for: 5)
        let reporter = PlaybackPositionReporter(api: api, store: store)

        let flush = Task { await reporter.flushPending() }
        await api.waitForBlockedSave()
        store.useServer(URL(string: "https://server-b.test"))
        api.setActiveServerIdentity(serverB)
        api.releaseBlockedSave()
        await flush.value

        XCTAssertTrue(api.sentServerIdentities.isEmpty)
        store.useServer(URL(string: "https://server-a.test"))
        XCTAssertEqual(store.pending(), [5: 30])
    }

    func testOlderInFlightSuccessDoesNotClearNewerThrottledPosition() async throws {
        let api = ControlledSpyAPI()
        api.blockNextSave()
        let store = try makeStore()
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let reporter = PlaybackPositionReporter(api: api, store: store, now: { clock.now() })

        let firstRecord = Task {
            await reporter.record(id: 5, secs: 30, duration: 1000, force: false)
        }
        await api.waitForBlockedSave()

        clock.set(Date(timeIntervalSince1970: 4))
        await reporter.record(id: 5, secs: 34, duration: 1000, force: false)
        api.releaseBlockedSave()
        await firstRecord.value

        XCTAssertEqual(store.pending(), [5: 34])
        XCTAssertEqual(store.resolved(server: 30, for: 5), 34)
    }
}
