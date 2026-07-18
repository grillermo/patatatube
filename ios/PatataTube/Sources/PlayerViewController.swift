import SwiftUI
import AVKit

/// AVPlayerViewController wrapper. iOS pauses any player attached to a video
/// layer when the app backgrounds, so `attached` lets the parent detach the
/// player (audio continues) and reattach on foreground.
struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    let attached: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        // NowPlayingManager owns the lock screen; stop AVKit competing for it.
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if attached {
            if controller.player !== player { controller.player = player }
        } else if controller.player != nil {
            controller.player = nil
        }
    }
}
