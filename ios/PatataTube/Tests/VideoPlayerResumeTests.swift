import AVFoundation
import XCTest
import PatataTubeKit
@testable import PatataTube

@MainActor
final class VideoPlayerResumeTests: XCTestCase {
    func testSeeksOnlyForMeaningfulOffsets() {
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0))
        XCTAssertNil(VideoPlayerView.seekTarget(startSecs: 0.4))
        XCTAssertEqual(VideoPlayerView.seekTarget(startSecs: 91.5)?.seconds ?? 0, 91.5, accuracy: 0.01)
    }

    func testForceReportsOnlyPauseTransitions() {
        XCTAssertTrue(VideoPlayerView.shouldForceReportPosition(for: .paused))
        XCTAssertFalse(VideoPlayerView.shouldForceReportPosition(for: .playing))
        XCTAssertFalse(VideoPlayerView.shouldForceReportPosition(for: .waitingToPlayAtSpecifiedRate))
    }

    func testPauseSessionRequiresSameVideoAndItem() {
        let observedItem = AVPlayerItem(asset: AVMutableComposition())
        let nextItem = AVPlayerItem(asset: AVMutableComposition())

        XCTAssertTrue(VideoPlayerView.isSamePauseSession(
            observedVideoID: 41, observedItem: observedItem,
            activeVideoID: 41, activeItem: observedItem
        ))
        XCTAssertFalse(VideoPlayerView.isSamePauseSession(
            observedVideoID: 41, observedItem: observedItem,
            activeVideoID: 42, activeItem: observedItem
        ))
        XCTAssertFalse(VideoPlayerView.isSamePauseSession(
            observedVideoID: 41, observedItem: observedItem,
            activeVideoID: 41, activeItem: nextItem
        ))
        XCTAssertFalse(VideoPlayerView.isSamePauseSession(
            observedVideoID: 41, observedItem: observedItem,
            activeVideoID: 41, activeItem: nil
        ))
    }

    func testSetupCannotContinueAfterCancellationOrDisappearance() {
        XCTAssertTrue(VideoPlayerView.canContinueSetup(
            taskIsCancelled: false, hasDisappeared: false
        ))
        XCTAssertFalse(VideoPlayerView.canContinueSetup(
            taskIsCancelled: true, hasDisappeared: false
        ))
        XCTAssertFalse(VideoPlayerView.canContinueSetup(
            taskIsCancelled: false, hasDisappeared: true
        ))
    }
}
