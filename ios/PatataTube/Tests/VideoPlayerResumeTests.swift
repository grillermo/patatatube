import XCTest
import PatataTubeKit
@testable import PatataTube

final class VideoPlayerResumeTests: XCTestCase {
    func testSeeksOnlyForMeaningfulOffsets() {
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0))
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0.4))
        XCTAssertEqual(VideoPlayerView.seekTarget(startSecs: 91.5)?.seconds ?? 0, 91.5, accuracy: 0.01)
    }
}
