import SwiftUI
import AVKit

/// AVPlayerViewController wrapper. iOS pauses any player attached to a video
/// layer when the app backgrounds, so `attached` lets the parent detach the
/// player (audio continues) and reattach on foreground.
struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let attached: Bool
    let resumeAfterDetaching: Bool
    let onPlayerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlayerTap: onPlayerTap)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = attached ? player : nil
        controller.allowsPictureInPicturePlayback = false
        // NowPlayingManager owns the lock screen; stop AVKit competing for it.
        controller.updatesNowPlayingInfoCenter = false
        controller.view.addGestureRecognizer(context.coordinator.makeTapRecognizer())
        if !attached && resumeAfterDetaching {
            player.play()
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onPlayerTap = onPlayerTap
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
