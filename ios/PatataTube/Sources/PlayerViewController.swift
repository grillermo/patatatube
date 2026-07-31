import SwiftUI
import AVKit

@MainActor
class SceneReportingPlayerViewController: AVPlayerViewController {
    var onSceneAvailable: ((any OrientationLockScene) -> Void)?
    var playerWindowScene: (any OrientationLockScene)? { view.window?.windowScene }

    /// Hide the home indicator while a video is on screen, like the YouTube app.
    /// AVPlayerViewController only does this for itself in its own full-screen
    /// presentation; embedded in a SwiftUI `fullScreenCover` it stays inline, so
    /// the preference has to be stated here. `childForHomeIndicatorAutoHidden`
    /// is nil'd because UIKit otherwise forwards the question to AVKit's
    /// internal content controller and never asks us.
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let playerWindowScene { onSceneAvailable?(playerWindowScene) }
    }
}

/// AVPlayerViewController wrapper. iOS pauses any player attached to a video
/// layer when the app backgrounds, so `attached` lets the parent detach the
/// player (audio continues) and reattach on foreground.
struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let attached: Bool
    let resumeAfterDetaching: Bool
    let onPlayerTap: () -> Void
    let onSceneAvailable: (any OrientationLockScene) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlayerTap: onPlayerTap)
    }

    func makeUIViewController(context: Context) -> SceneReportingPlayerViewController {
        makePlayerViewController(coordinator: context.coordinator)
    }

    func makePlayerViewController(coordinator: Coordinator) -> SceneReportingPlayerViewController {
        let controller = SceneReportingPlayerViewController()
        controller.player = attached ? player : nil
        controller.allowsPictureInPicturePlayback = false
        // NowPlayingManager owns the lock screen; stop AVKit competing for it.
        controller.updatesNowPlayingInfoCenter = false
        controller.onSceneAvailable = onSceneAvailable
        controller.view.addGestureRecognizer(coordinator.makeTapRecognizer())
        if !attached && resumeAfterDetaching {
            player.play()
        }
        return controller
    }

    func updateUIViewController(_ controller: SceneReportingPlayerViewController, context: Context) {
        context.coordinator.onPlayerTap = onPlayerTap
        controller.onSceneAvailable = onSceneAvailable
        if attached {
            if controller.player !== player { controller.player = player }
        } else if controller.player != nil {
            controller.player = nil
            if resumeAfterDetaching {
                player.play()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPlayerTap: () -> Void

        init(onPlayerTap: @escaping () -> Void) {
            self.onPlayerTap = onPlayerTap
        }

        @objc func tapped() { onPlayerTap() }

        func makeTapRecognizer() -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
