import XCTest
@testable import PatataTubeKit

final class AudioHandbackTests: XCTestCase {
    func testDismissingAPlayerOpenedFromTheMiniPlayerHandsBackToAudio() {
        XCTAssertTrue(shouldReturnToAudio(cameFromAudio: true, isHandingOff: false, reachedEnd: false))
    }

    func testAPlayerOpenedAnyOtherWayNeverStartsAudio() {
        XCTAssertFalse(shouldReturnToAudio(cameFromAudio: false, isHandingOff: false, reachedEnd: false))
    }

    func testPictureInPictureHandoffKeepsThePlayerAndDoesNotHandBack() {
        XCTAssertFalse(shouldReturnToAudio(cameFromAudio: true, isHandingOff: true, reachedEnd: false))
    }

    func testAnItemThatPlayedToItsEndDoesNotRestartAsAudio() {
        XCTAssertFalse(shouldReturnToAudio(cameFromAudio: true, isHandingOff: false, reachedEnd: true))
    }
}
