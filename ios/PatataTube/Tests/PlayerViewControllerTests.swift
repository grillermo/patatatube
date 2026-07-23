import AVFoundation
import SwiftUI
import Testing
import UIKit
import ViewInspector
@testable import PatataTube

@Suite("Player view controller bridge")
@MainActor
struct PlayerViewControllerTests {
    @Test func installsOneNonCancellingTapRecognizer() {
        let sut = PlayerViewController(
            player: AVPlayer(),
            attached: true,
            resumeAfterDetaching: false,
            onPlayerTap: {}
        )
        let coordinator = sut.makeCoordinator()
        let recognizer = coordinator.makeTapRecognizer()
        #expect(recognizer.cancelsTouchesInView == false)
        #expect(recognizer.delegate === coordinator)
    }

    @Test func normalAndSleepPlayersBothContainTheOrientationOverlay() throws {
        let model = AppModel()
        for sleepMode in [false, true] {
            let sut = VideoPlayerView(
                videos: [], startIndex: 0, sleepMode: sleepMode
            )
            .environmentObject(model)
            #expect(try sut.inspect().find(OrientationLockOverlay.self) != nil)
        }
    }
}
