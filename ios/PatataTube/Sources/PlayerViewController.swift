import SwiftUI
import AVKit

@MainActor
class SceneReportingPlayerViewController: AVPlayerViewController {
    var onSceneAvailable: ((any HorizontalLockScene) -> Void)?
    var playerWindowScene: (any HorizontalLockScene)? { view.window?.windowScene }

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
        if pendingControlReveal {
            pendingControlReveal = false
            forceControlsVisible()
        }
    }

    private var pendingControlReveal = false

    /// AVKit exposes no "show the controls" call, so this off/on flip of
    /// `showsPlaybackControls` re-runs its own reveal (the same path a tap
    /// takes). Before `viewDidAppear` the flip is swallowed, so it is deferred.
    func revealPlaybackControls() {
        guard isViewLoaded, view.window != nil else {
            pendingControlReveal = true
            return
        }
        forceControlsVisible()
    }

    private func forceControlsVisible() {
        showsPlaybackControls = false
        DispatchQueue.main.async { [weak self] in
            self?.showsPlaybackControls = true
        }
    }
}

/// AVPlayerViewController wrapper. iOS pauses any player attached to a video
/// layer when the app backgrounds, so `attached` lets the parent detach the
/// player (audio continues) and reattach on foreground.
struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Owns PiP once it starts, and is AVKit's delegate for it — the coordinator
    /// can't be, since it dies with this representable when the cover dismisses.
    let pip: PiPSession
    let attached: Bool
    let resumeAfterDetaching: Bool
    /// Every change of this value forces the transport controls back on screen.
    /// A restored session mounts paused, and AVKit leaves the bar hidden until
    /// a tap; the parent bumps this so the controls are there immediately.
    let revealControlsToken: Int
    let onPlayerTap: () -> Void
    let onSceneAvailable: (any HorizontalLockScene) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlayerTap: onPlayerTap)
    }

    func makeUIViewController(context: Context) -> SceneReportingPlayerViewController {
        let controller = makePlayerViewController(coordinator: context.coordinator)
        // The mount and the token bump land in the same update, so a restored
        // session never reaches `updateUIViewController` with a stale token.
        context.coordinator.lastRevealToken = revealControlsToken
        if revealControlsToken > 0 { controller.revealPlaybackControls() }
        return controller
    }

    func makePlayerViewController(coordinator: Coordinator) -> SceneReportingPlayerViewController {
        let controller = SceneReportingPlayerViewController()
        controller.player = attached ? player : nil
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = pip
        pip.register(controller: controller)
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
        if context.coordinator.lastRevealToken != revealControlsToken {
            context.coordinator.lastRevealToken = revealControlsToken
            controller.revealPlaybackControls()
        }
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
        /// Last `revealControlsToken` acted on, so one bump reveals once.
        var lastRevealToken = 0

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
