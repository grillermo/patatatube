import AVFoundation
import SwiftUI
import PatataTubeKit
import Testing
import UIKit
import ViewInspector
@testable import PatataTube

/// `VideoPlayerView.video` is `videos[currentIndex]`, so an empty list traps.
private let sampleVideo = Video(
    id: 1,
    url: "/videos/1",
    title: "Video 1",
    platform: nil,
    sourceKey: nil,
    previewUrl: nil,
    groupID: nil,
    plexKind: .movies,
    position: 1,
    status: "done",
    errorMsg: nil,
    streamPath: "/videos/1/stream"
)

@Suite("Player view controller bridge")
@MainActor
struct PlayerViewControllerTests {
    @Test func installedControllerHasExactlyOneNonCancellingSimultaneousTapRecognizer() throws {
        let sut = PlayerViewController(
            player: AVPlayer(),
            pip: PiPSession(),
            attached: true,
            resumeAfterDetaching: false,
            revealControlsToken: 0,
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
        var receivedScene: (any HorizontalLockScene)?
        controller.onSceneAvailable = { receivedScene = $0 }

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        #expect(controller.view.window === window)
        #expect(receivedScene?.horizontalLockIdentifier == ObjectIdentifier(scene))
    }

    @Test func playerControllerHidesTheHomeIndicatorItself() {
        let controller = SceneReportingPlayerViewController()

        #expect(controller.prefersHomeIndicatorAutoHidden)
        // AVKit's internal content controller must not answer instead of ours.
        #expect(controller.childForHomeIndicatorAutoHidden == nil)
    }

    /// Disabled, not deleted: the assertion is still the one we want, but
    /// ViewInspector cannot reach this view any more. To supply the
    /// `@EnvironmentObject`, `EnvironmentInjection.inject` scans a copy of the
    /// view struct for the object's slot by writing sentinel bytes at guessed
    /// offsets (ViewInspector 0.10.3, EnvironmentInjection.swift:37-47). On
    /// VideoPlayerView's current layout — ~20 stored properties, most of them
    /// single-pointer `@State` — a guess lands inside a refcounted field and the
    /// next copy of the struct segfaults in `initializeWithCopy`. Hosting first
    /// and using `inspect(function:)` does not help; the injector runs either
    /// way. The segfault kills the test process, so it cannot be tolerated with
    /// `withKnownIssue` either. Re-enabling means giving VideoPlayerView a real
    /// inspection seam (ViewInspector's `Inspection` + `.onReceive`) so the
    /// instance comes from SwiftUI with its environment already populated.
    @Test(.disabled("ViewInspector 0.10.3 segfaults injecting AppModel into VideoPlayerView"))
    func normalAndSleepPlayersBothContainTheOrientationOverlay() throws {
        for sleepMode in [false, true] {
            let sut = VideoPlayerView(
                videos: [sampleVideo], startIndex: 0, sleepMode: sleepMode
            )
            .environmentObject(AppModel())
            ViewHosting.host(view: sut, function: #function)
            defer { ViewHosting.expel(function: #function) }
            #expect(try sut.inspect(function: #function)
                .find(HorizontalLockOverlay.self) != nil)
        }
    }
}
