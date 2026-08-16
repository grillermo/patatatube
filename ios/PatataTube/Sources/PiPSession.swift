// ios/PatataTube/Sources/PiPSession.swift
import AVKit
import PatataTubeKit
import SwiftUI

/// Owns Picture in Picture for the whole app.
///
/// PiP is entered through AVKit's own button in the transport bar. There is no
/// API to start it — an overlay chevron that fired that button by hand was tried
/// and removed, because it never worked on device — so everything the float does
/// (its controls, restore and close, surviving backgrounding) is AVKit's.
///
/// What is left for us is the handoff, because AVKit can dismiss its own
/// presentation but not a SwiftUI `fullScreenCover`. So this object outlives
/// `VideoPlayerView`: it is staged with the player while the cover is up, and
/// once PiP starts it dismisses that cover, after which its retained controller
/// and player are the only things keeping the float alive.
@MainActor
final class PiPSession: NSObject, ObservableObject, AVPlayerViewControllerDelegate {
    /// True from `willStart` until PiP stops. `VideoPlayerView` reads it on
    /// dismiss to skip the teardown that would kill the float. It has to be set
    /// at *will*Start, not `didStart`: the cover is dismissed there, and its
    /// `onDisappear` would otherwise run before PiP is considered live.
    @Published private(set) var isHandingOff = false
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
    /// Called once, on `willStart`, to dismiss the presenting cover.
    private var onStart: (() -> Void)?

    /// A fresh player view took over. If one was *floating*, end it rather than
    /// silently dropping the controller that owns it (which would strand the
    /// old player, still playing, with no delegate left to stop it).
    ///
    /// Only then: a player view stages its handoff (`prepare`) as soon as it has
    /// a player, but mounts its controller once the item has buffered — either
    /// order — so releasing unconditionally here threw away the staging of the
    /// very view registering, `onStart` with it, and nothing dismissed the cover
    /// when PiP started.
    func register(controller: AVPlayerViewController) {
        if isHandingOff, self.controller !== controller { release() }
        self.controller = controller
    }

    /// Stages everything the float will need. AVKit gives no warning before PiP
    /// starts, so this is called as soon as a player exists and again whenever
    /// the queue moves — by the time `willStart` arrives it is too late to ask
    /// the cover for anything.
    func prepare(
        player: AVPlayer,
        positionObserver: Any?,
        videos: [Video],
        index: Int,
        sleepMode: Bool,
        scope: String?,
        randomize: Bool,
        onStart: @escaping () -> Void
    ) {
        guard !isHandingOff else { return }  // never restage a live float
        self.player = player
        self.positionObserver = positionObserver
        self.videos = videos
        self.index = index
        self.sleepMode = sleepMode
        self.scope = scope
        self.randomize = randomize
        self.onStart = onStart
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
        isHandingOff = false
    }

    // MARK: - AVPlayerViewControllerDelegate

    /// AVKit can dismiss its own presentation, but not a SwiftUI
    /// `fullScreenCover`; `willStart` does that instead.
    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool { false }

    /// Dismissing here rather than at `didStart` is what keeps AVKit's
    /// "Playing in Picture in Picture" placeholder off the screen: that black
    /// panel is what the player view shows *while it is still presented* and
    /// the video is elsewhere. Gone before PiP starts, it is never drawn.
    nonisolated func playerViewControllerWillStartPictureInPicture(
        _ playerViewController: AVPlayerViewController
    ) {
        MainActor.assumeIsolated {
            isHandingOff = true
            DevLog.event(.nav, "pip starting", [:])
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
            // The cover is already gone by now (dismissed at `willStart`), so
            // leaving the player running would mean audio with no video and no
            // float. Before that point it is still the cover's to run.
            release(pausing: isHandingOff)
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

}
