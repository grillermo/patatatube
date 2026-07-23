import SwiftUI
import AVKit

@MainActor
class SceneReportingPlayerViewController: AVPlayerViewController {
    var onSceneAvailable: ((any OrientationLockScene) -> Void)?
    var playerWindowScene: (any OrientationLockScene)? { view.window?.windowScene }

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
