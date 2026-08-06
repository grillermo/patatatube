import Testing
import Foundation
@testable import PatataTubeKit

private actor StubJobsAPI: JobsAPI {
    private var snapshots: [JobsSnapshot]
    private(set) var callCount = 0

    init(_ snapshots: [JobsSnapshot]) { self.snapshots = snapshots }

    func jobs() async throws -> JobsSnapshot {
        callCount += 1
        return snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? .empty)
    }

    func calls() -> Int { callCount }
}

private func job(id: Int, videoID: Int, progress: Double?) -> ConversionJob {
    ConversionJob(id: id, videoID: videoID, versionID: nil, kind: "convert",
                  progress: progress, title: "Video \(videoID)", showTitle: nil)
}

@Suite("Jobs store")
@MainActor
struct JobsStoreTests {
    @Test func refreshNowPublishesTheSnapshot() async {
        let snapshot = JobsSnapshot(running: [job(id: 1, videoID: 9, progress: 0.5)],
                                    queued: [], queuedTotal: 0)
        let store = JobsStore(api: StubJobsAPI([snapshot]))
        await store.refreshNow()
        #expect(store.snapshot == snapshot)
    }

    @Test func stateIsRunningWithProgressForARunningJob() async {
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [job(id: 1, videoID: 9, progress: 0.42)],
                         queued: [], queuedTotal: 0)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 9) == .running(0.42))
    }

    @Test func stateIsQueuedForAQueuedJobAndNilForAnythingElse() async {
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [], queued: [job(id: 2, videoID: 7, progress: nil)],
                         queuedTotal: 1)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 7) == .queued)
        #expect(store.state(videoID: 99) == nil)
    }

    @Test func aRunningJobWithoutANumberReadsAsQueued() async {
        // The row is claimed but ffmpeg has not reported yet -- the UI should
        // keep spinning rather than flash 0%.
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [job(id: 1, videoID: 5, progress: nil)],
                         queued: [], queuedTotal: 0)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 5) == .queued)
    }

    @Test func subscribingStartsPollingAndUnsubscribingStopsIt() async throws {
        let api = StubJobsAPI([.empty])
        nonisolated(unsafe) var sleeps = 0
        let store = JobsStore(api: api, sleep: { _ in
            sleeps += 1
            if sleeps > 3 { throw CancellationError() }
        })
        store.subscribe()
        while await api.calls() < 3 { await Task.yield() }
        store.unsubscribe()
        let settled = await api.calls()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await api.calls() == settled)
    }

    @Test func theLoopRunsOnceForOverlappingSubscribers() async {
        let api = StubJobsAPI([.empty])
        let store = JobsStore(api: api, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        store.subscribe()
        store.subscribe()
        while await api.calls() < 2 { await Task.yield() }
        store.unsubscribe()
        // One subscriber remains, so polling continues.
        let before = await api.calls()
        while await api.calls() == before { await Task.yield() }
        store.unsubscribe()
    }

    @Test func aFailedPollKeepsTheLastSnapshot() async {
        struct FailingAPI: JobsAPI {
            func jobs() async throws -> JobsSnapshot { throw APIError.badStatus(500) }
        }
        let snapshot = JobsSnapshot(running: [job(id: 1, videoID: 3, progress: 0.1)],
                                    queued: [], queuedTotal: 0)
        let store = JobsStore(api: StubJobsAPI([snapshot]))
        await store.refreshNow()
        let failing = JobsStore(api: FailingAPI())
        await failing.refreshNow()
        #expect(failing.snapshot == .empty)
        #expect(store.snapshot == snapshot)
    }
}
