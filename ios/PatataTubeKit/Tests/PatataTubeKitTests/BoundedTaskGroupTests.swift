import Foundation
import Testing
@testable import PatataTubeKit

/// Observes concurrency from outside the operations themselves. An actor
/// because the operations run on MainActor but the counters must be safe to
/// read from the test's own context.
private actor Tracker {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var seen: [Int] = []

    func enter(_ id: Int) {
        active += 1
        maxActive = max(maxActive, active)
        seen.append(id)
    }

    func leave() { active -= 1 }
}

@Suite("Bounded task group")
@MainActor
struct BoundedTaskGroupTests {

    @Test
    func neverExceedsTheLimit() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 3, over: Array(0..<20)) { id in
            await tracker.enter(id)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await tracker.leave()
        }

        #expect(await tracker.maxActive <= 3)
        // Proves the window is actually parallel, not accidentally serial.
        #expect(await tracker.maxActive > 1)
        #expect(await tracker.seen.count == 20)
    }

    @Test
    func runsEveryItemExactlyOnce() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 4, over: Array(0..<50)) { id in
            await tracker.enter(id)
            await tracker.leave()
        }

        #expect(await tracker.seen.count == 50)
        #expect(Set(await tracker.seen) == Set(0..<50))
    }

    @Test
    func clampsNonPositiveLimitToOne() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 0, over: Array(0..<5)) { id in
            await tracker.enter(id)
            try? await Task.sleep(nanoseconds: 2_000_000)
            await tracker.leave()
        }

        #expect(await tracker.maxActive == 1)
        #expect(await tracker.seen.count == 5)
    }

    @Test
    func emptyInputRunsNothing() async {
        let tracker = Tracker()

        await withBoundedTaskGroup(limit: 3, over: [Int]()) { id in
            await tracker.enter(id)
            await tracker.leave()
        }

        #expect(await tracker.seen.isEmpty)
    }

    @Test
    func cancelledParentStopsSeeding() async {
        let tracker = Tracker()

        let task = Task { @MainActor in
            await withBoundedTaskGroup(limit: 1, over: Array(0..<50)) { id in
                await tracker.enter(id)
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.leave()
            }
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        await task.value

        // Without the cancellation check the loop keeps seeding, and because a
        // cancelled Task.sleep returns immediately all 50 would run anyway.
        #expect(await tracker.seen.count < 50)
    }
}
