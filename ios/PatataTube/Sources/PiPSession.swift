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
    /// Whether the presentation `restoreRequest` asks for was opened *by* the
    /// audio mini player. `VideoPlayerView` reads it on dismiss to decide
    /// whether to hand playback back to `AudioQueuePlayer` (see
    /// `shouldReturnToAudio`). Every restore path sets it, so a PiP restore
    /// can never inherit an audio tap's flag.
    private(set) var restoreCameFromAudio = false
    /// The live `AVPlayer` the audio mini player handed over for
    /// `restoreRequest` to adopt, still playing. Read (without consuming) by
    /// the presentation site, taken by `VideoPlayerView.setup` — non-nil only
    /// between the bar's tap and that adoption, so a restore reached any other
    /// way finds nothing here.
    private(set) var restoreAdoptedPlayer: AVPlayer?

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

    /// External restore request: the audio-only mini-player's thumbnail/title
    /// tap hands its current item to the full-screen player the same way the
    /// floating PiP button's own restore does, reusing the one presentation
    /// site `RootTabView` already wires to `restoreRequest` (whose `onChange`
    /// stops the audio-only queue for us — no float here to release).
    func restoreFullScreen(
        video: Video, queueSnapshot: [Video], sleepMode: Bool,
        startSecs: Double, scope: String?, randomize: Bool,
        adoptedPlayer: AVPlayer? = nil
    ) {
        restoreScope = scope
        restoreRandomize = randomize
        restoreCameFromAudio = true
        clearAdoptedPlayer()
        restoreAdoptedPlayer = adoptedPlayer
        restoreRequest = PlaybackQueue(
            video: video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, startSecs: startSecs
        )
    }

    /// Drops staging that never became a float. `prepare` runs as soon as a
    /// player exists, so a player view that is dismissed without PiP ever
    /// starting leaves us holding its player *and* the periodic observer it
    /// has already removed on its way out. Left in place, the next
    /// `stopFloating()` removes that observer a second time and AVPlayer
    /// throws `NSInvalidArgumentException` (PATATATUBE-K). Scoped by identity
    /// so a newer view's staging is never dropped by an older view's teardown,
    /// and refused outright while a float is live — there the handoff, not the
    /// departing cover, owns the player.
    func cancelStaging(for player: AVPlayer) {
        guard !isHandingOff, self.player === player else { return }
        self.player = nil
        positionObserver = nil
        videos = []
        onStart = nil
    }

    /// Takes the handed-over player for the presentation that is adopting it.
    /// Consuming, so exactly one owner ends up with it.
    func takeAdoptedPlayer() -> AVPlayer? {
        defer { restoreAdoptedPlayer = nil }
        return restoreAdoptedPlayer
    }

    /// Drops a handed-over player nothing adopted. Pausing is the point: it is
    /// still playing, and letting go of the last reference to it without that
    /// would leave sound coming out of an object no screen can control.
    private func clearAdoptedPlayer() {
        restoreAdoptedPlayer?.pause()
        restoreAdoptedPlayer = nil
    }

    /// Hands a player out of the controller it was mounted in, for the one
    /// dismissal that keeps it playing: the audio mini player adopting the
    /// full-screen player's `AVPlayer` (`shouldReturnToAudio`). The departing
    /// `AVPlayerViewController` — retained here until the next `register` —
    /// must not be left owning a player that is now the audio queue's, which
    /// is the same detach the backgrounding path performs through `attached`.
    ///
    /// Scoped by identity, and refused while a float is live: there the
    /// controller *is* the playback surface, and clearing its player would
    /// close the float.
    func releaseController(for player: AVPlayer) {
        guard !isHandingOff, controller?.player === player else { return }
        controller?.player = nil
        controller = nil
    }

    /// Tears down an active float from the outside — the audio-only queue calls
    /// this before it starts, since starting audio and a floating PiP video are
    /// the same "one audio source at a time" invariant from the other
    /// direction. A no-op when nothing is floating: staged-but-not-floating
    /// state belongs to a live player view, whose observers are its own to
    /// remove, so `isHandingOff` — not `player` — is what says a float exists.
    func stopFloating() {
        guard isHandingOff else { return }
        release()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            restoreCameFromAudio = false
            clearAdoptedPlayer()
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
