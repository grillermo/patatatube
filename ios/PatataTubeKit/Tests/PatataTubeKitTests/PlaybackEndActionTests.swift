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
}
