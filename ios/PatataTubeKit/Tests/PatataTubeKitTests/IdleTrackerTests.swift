import XCTest
@testable import PatataTubeKit

final class IdleTrackerTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

    private func makeTracker(_ clock: Clock) -> IdleTracker {
        let defaults = UserDefaults(suiteName: "IdleTrackerTests-\(UUID().uuidString)")!
        return IdleTracker(defaults: defaults, now: { clock.now })
    }

    func testFirstLaunchIsNotStale() {
        XCTAssertFalse(makeTracker(Clock()).isStale())
    }

    func testWithinAnHourIsNotStale() {
        let clock = Clock()
        let tracker = makeTracker(clock)
        tracker.markEngaged()
        clock.now += 3600
        XCTAssertFalse(tracker.isStale())
    }

    func testPastAnHourIsStale() {
        let clock = Clock()
        let tracker = makeTracker(clock)
        tracker.markEngaged()
        clock.now += 3601
        XCTAssertTrue(tracker.isStale())
    }

    func testEngagingAgainResetsTheClock() {
        let clock = Clock()
        let tracker = makeTracker(clock)
        tracker.markEngaged()
        clock.now += 3000
        tracker.markEngaged()
        clock.now += 3000
        XCTAssertFalse(tracker.isStale())
    }
}
