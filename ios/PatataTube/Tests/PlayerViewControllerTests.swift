import AVFoundation
import SwiftUI
import Testing
import UIKit
import ViewInspector
@testable import PatataTube

@Suite("Player view controller bridge")
@MainActor
struct PlayerViewControllerTests {
    @Test func installedControllerHasExactlyOneNonCancellingSimultaneousTapRecognizer() throws {
        let sut = PlayerViewController(
            player: AVPlayer(),
            attached: true,
            resumeAfterDetaching: false,
            onPlayerTap: {},
            onSceneAvailable: { _ in }
        )
        let coordinator = sut.makeCoordinator()
        let controller = sut.makePlayerViewController(coordinator: coordinator)
        let customRecognizers = (controller.view.gestureRecognizers ?? []).filter {
            $0.delegate === coordinator
        }

        #expect(customRecognizers.count == 1)
        let recognizer = try #require(customRecognizers.first)
        #expect(recognizer.cancelsTouchesInView == false)
        #expect(recognizer.delegate === coordinator)
        #expect(coordinator.gestureRecognizer(
            recognizer,
            shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()
        ))
    }

    @Test func appearingControllerReportsItsExactPlayerWindowScene() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let controller = SceneReportingPlayerViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.addSubview(controller.view)
        var receivedScene: (any OrientationLockScene)?
        controller.onSceneAvailable = { receivedScene = $0 }

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        #expect(controller.view.window === window)
        #expect(receivedScene?.orientationLockIdentifier == ObjectIdentifier(scene))
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
