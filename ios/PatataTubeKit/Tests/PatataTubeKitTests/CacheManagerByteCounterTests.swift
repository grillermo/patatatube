import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager cumulative byte counter")
struct CacheManagerByteCounterTests {
    // A resumed segmented download (`resumeInterrupted`) or one seeded from
    // previously-streamed parts registers its key with an accumulator that
    // already has bytes on disk baked into `transferredByteCount` — the
    // accumulator goes straight from absent to present holding a non-zero
    // count, rather than starting at 0 and being updated in a later tick.
    // `InFlightActivities` is internal, not the private `CacheManager.inFlight`
    // it backs, so it's reachable directly here via `@testable import` without
    // needing a full manifest/network resume to exercise the same subscript.
    @Test func registeringAnAlreadySeededDownloadDoesNotSpikeTheCounter() {
        var activities = InFlightActivities()

        var seeded = DownloadActivityAccumulator(videoID: 1, versionID: nil, totalByteCount: 1_000)
        seeded.record(transferredByteCount: 400, progress: 0.4)
        activities["1"] = seeded
        #expect(activities.cumulativeByteCount == 0)

        // A genuine progress update after registration still counts normally.
        seeded.record(transferredByteCount: 600, progress: 0.6)
        activities["1"] = seeded
        #expect(activities.cumulativeByteCount == 200)
    }

    // The counters exist so a flat readout can be attributed to a layer.
    @Test func writeTalliesDistinguishUpdatesFromTransitions() {
        var activities = InFlightActivities()
        var accumulator = DownloadActivityAccumulator(videoID: 1, versionID: nil, totalByteCount: 10)
        activities["1"] = accumulator          // insert  -> transition
        accumulator.record(transferredByteCount: 4, progress: 0.4)
        activities["1"] = accumulator          // update  -> delta 4
        activities["1"] = accumulator          // update  -> delta 0
        activities["1"] = nil                  // remove  -> transition

        #expect(activities.writeCount == 4)
        #expect(activities.updateWriteCount == 2)
        #expect(activities.zeroDeltaCount == 1)
        #expect(activities.transitionCount == 2)
        #expect(activities.cumulativeByteCount == 4)
    }
}
