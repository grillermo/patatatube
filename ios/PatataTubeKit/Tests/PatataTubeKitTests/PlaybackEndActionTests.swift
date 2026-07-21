import XCTest
@testable import PatataTubeKit

final class PlaybackEndActionTests: XCTestCase {
    func testAutoplayOnAdvancesInForeground() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: true), .advance)
    }

    func testAutoplayOnAdvancesWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: false), .advance)
    }

    func testAutoplayOffDismissesInForeground() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: true), .dismiss)
    }

    func testAutoplayOffStopsWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: false), .stop)
    }

    func testSleepModeWinsOverAutoplay() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: true, sleepMode: true), .sleep)
    }

    func testSleepModeWinsWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: false, sleepMode: true), .sleep)
    }

    func testSleepModeOffKeepsExistingBehavior() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: true, sleepMode: false), .dismiss)
    }
}
