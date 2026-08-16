// ios/PatataTube/Sources/PiPSession.swift
import AVKit
import PatataTubeKit
import SwiftUI

/// Owns Picture in Picture for the whole app.
///
/// AVKit exposes no way to *start* PiP programmatically: `AVPlayerViewController`
/// has only `allowsPictureInPicturePlayback`, the background-only
/// `canStartPictureInPictureAutomaticallyFromInline`, and delegate callbacks —
/// and `AVPictureInPictureController` can only be built from an `AVPlayerLayer`,
/// which `AVPlayerViewController` never hands out. So the chevron fires AVKit's
/// own PiP button, which is exactly the path a tap on that button takes. All the
/// behaviour after that (the float, its controls, its restore and close buttons,
/// surviving backgrounding) is AVKit's.
///
/// This object outlives `VideoPlayerView`. Once PiP starts the SwiftUI cover is
/// dismissed, and the retained controller and player here are the only things
/// keeping the float alive.
@MainActor
final class PiPSession: NSObject, ObservableObject, AVPlayerViewControllerDelegate {
    /// True from `didStart` until PiP stops. `VideoPlayerView` reads it on
    /// dismiss to skip the teardown that would kill the float.
    @Published private(set) var isActive = false
    /// Set when PiP's restore button is hit; `RootTabView` presents it.
    @Published var restoreRequest: PlaybackQueue?
    /// `PlaybackQueue` carries neither, and the restored presentation needs both.
    private(set) var restoreScope: String?
    private(set) var restoreRandomize = false

    /// Retained across the cover's dismissal — SwiftUI drops both.
    private var controller: AVPlayerViewController?
    private var player: AVPlayer?
    /// The player view's periodic observer, taken over so resume positions keep
    /// being reported during PiP. Removing it before the player goes away is
    /// what avoids AVPlayer's "deallocated while its time observer was still
    /// registered" trap.
    private var positionObserver: Any?
    private var videos: [Video] = []
    private var index = 0
    private var sleepMode = false
    private var scope: String?
    private var randomize = false
    /// Called once, on `didStart`, to dismiss the presenting cover.
    private var onStart: (() -> Void)?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// A fresh player view took over; if one was floating, end it rather than
    /// silently dropping the controller that owns it (which would strand the
    /// old player, still playing, with no delegate left to stop it).
    func register(controller: AVPlayerViewController) {
        if self.controller !== controller { release() }
        self.controller = controller
    }

    /// Hands over everything the float needs, then fires AVKit's button.
    /// Returns false — having kept nothing — if PiP can't be started, leaving
    /// the full-screen player exactly as it was.
    @discardableResult
    func start(
        player: AVPlayer,
        positionObserver: Any?,
        videos: [Video],
        index: Int,
        sleepMode: Bool,
        scope: String?,
        randomize: Bool,
        onStart: @escaping () -> Void
    ) -> Bool {
        guard isSupported, let controller,
              let button = Self.pictureInPictureButton(in: controller.view) else {
            DevLog.event(.nav, "pip unavailable", [
                "supported": "\(isSupported)", "controller": "\(self.controller != nil)",
            ])
            return false
        }
        self.player = player
        self.positionObserver = positionObserver
        self.videos = videos
        self.index = index
        self.sleepMode = sleepMode
        self.scope = scope
        self.randomize = randomize
        self.onStart = onStart
        DevLog.event(.nav, "pip requested", [
            "video_id": "\(videos.indices.contains(index) ? videos[index].id : -1)",
        ])
        button.sendActions(for: .touchUpInside)
        return true
    }

    /// Ends the float and everything handed over with it. Safe to call twice.
    private func release(pausing: Bool = true) {
        if let positionObserver { player?.removeTimeObserver(positionObserver) }
        positionObserver = nil
        if pausing { player?.pause() }
        player = nil
        controller = nil
        videos = []
        onStart = nil
        isActive = false
    }

    // MARK: - AVPlayerViewControllerDelegate

    /// AVKit can dismiss its own presentation, but not a SwiftUI
    /// `fullScreenCover`; `didStart` does that instead.
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool { false }

    nonisolated func playerViewControllerDidStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        MainActor.assumeIsolated {
            isActive = true
            DevLog.event(.nav, "pip started", [:])
            onStart?()
            onStart = nil
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated {
            DevLog.error(error, "pip failed to start")
            // The cover is still up and still owns the player: drop the
            // handover without touching playback.
            release(pausing: false)
        }
    }

    /// The float's restore button. The full-screen player is rebuilt from the
    /// queue snapshot at the current time rather than threading the live player
    /// back through the cover — a sub-second re-buffer for no ownership plumbing.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        // AVKit always calls this on the main thread, but the block itself isn't
        // Sendable, so it has to be carried across `assumeIsolated` by hand.
        nonisolated(unsafe) let completionHandler = completionHandler
        MainActor.assumeIsolated {
            guard let player, videos.indices.contains(index) else {
                release()
                completionHandler(false)
                return
            }
            let secs = player.currentTime().seconds
            restoreScope = scope
            restoreRandomize = randomize
            restoreRequest = PlaybackQueue(
                video: videos[index], queueSnapshot: videos, sleepMode: sleepMode,
                startSecs: secs.isFinite ? secs : 0
            )
            DevLog.event(.nav, "pip restore", ["secs": "\(Int(secs.isFinite ? secs : 0))"])
            // Released here rather than in `didStop`: the incoming player view
            // registers its own controller, and this one must be gone by then.
            release()
            completionHandler(true)
        }
    }

    /// Reached without a restore when the user closes the float.
    nonisolated func playerViewControllerDidStopPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        MainActor.assumeIsolated {
            guard player != nil else { return }  // already released by restore
            DevLog.event(.nav, "pip stopped", [:])
            release()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Finding AVKit's button

    /// Breadth-first search for AVKit's PiP button. It is matched by its
    /// accessibility identifier and, failing that, by its image compared
    /// against `AVPictureInPictureController.pictureInPictureButtonStartImage`
    /// — a documented class property, so at least one of the two signals is
    /// public API.
    static func pictureInPictureButton(in root: UIView) -> UIControl? {
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let control = view as? UIControl, isPictureInPictureButton(control) {
                return control
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func isPictureInPictureButton(_ control: UIControl) -> Bool {
        let names = [control.accessibilityIdentifier, control.accessibilityLabel,
                     String(describing: type(of: control))]
        if names.compactMap({ $0 }).contains(where: { $0.localizedCaseInsensitiveContains("picture") }) {
            return true
        }
        guard let button = control as? UIButton,
              let image = button.currentImage ?? button.image(for: .normal) else { return false }
        let start = AVPictureInPictureController.pictureInPictureButtonStartImage
        return image === start || image.isEqual(start)
    }
}
