// ios/PatataTube/Sources/AudioQueuePlayer.swift
import AVFoundation
import Combine
import PatataTubeKit
import UIKit

/// Audio-only queue playback for the group-detail list: the same assets the
/// full-screen player uses, with nothing displaying them.
///
/// Lives on `AppModel` (like `pip`) because playback has to survive switching to
/// grid, navigating back, changing tabs, and backgrounding — the list row that
/// started it is gone from the hierarchy long before the queue ends. An
/// `AVPlayer` over a video asset simply renders no frames when no layer is
/// attached, so there is no audio-only asset to build.
///
/// Positions are deliberately not involved: audio always starts at 0 and never
/// writes to `PlaybackPositionReporter`.
@MainActor
final class AudioQueuePlayer: ObservableObject {
    /// The video whose audio is loaded, or nil when nothing is playing.
    @Published private(set) var currentID: Int?
    @Published private(set) var isPlaying: Bool = false
    /// A tap whose source isn't resolved yet (`/prepare`, conversion). Keyed by
    /// id rather than a flag, so a second tap elsewhere moves the spinner.
    @Published private(set) var loadingID: Int?

    private var player: AVPlayer?
    private var navigator: QueueNavigator?
    private var scope: String?
    private var sleepAfterCurrent = false
    private weak var model: AppModel?
    private let nowPlaying = NowPlayingManager()
    private var playToEndObserver: NSObjectProtocol?
    private var rateObservation: NSKeyValueObservation?
    /// Bumped by every `start()`/`stop()` call. `start()`'s unstructured `Task`
    /// captures the value at launch and checks it after each `await`, so a
    /// stale continuation from a superseded call can never clobber state a
    /// newer call has already written — it just bails out silently instead.
    private var startGeneration = 0

    /// How a given row should draw itself.
    func state(for videoID: Int) -> RowAudioState {
        if loadingID == videoID { return .loading }
        guard currentID == videoID else { return .idle }
        return isPlaying ? .playing : .paused
    }

    /// Marks a row as waiting on `ensureReady`. Pass nil to clear.
    func markLoading(id: Int?) { loadingID = id }

    /// The scope the current queue's autoplay/randomize settings are keyed
    /// under (`AppModel.autoplayBinding(for:)`/`randomizeBinding(for:)`), for
    /// the mini-player bar's toggles. Nil only when nothing is playing.
    var currentScope: String? { scope }

    /// Start (or restart) the queue at `startIndex`, from the beginning of the
    /// item. Any previous audio and any pending loading marker are dropped
    /// first.
    ///
    /// Positions stay out of it in both directions: this builds a fresh item at
    /// 0, and the one case that resumes mid-item — the full-screen player
    /// handing playback back on dismiss — goes through `adopt` with the running
    /// player instead, so there is nothing to seek to.
    func start(videos: [Video], startIndex: Int, scope: String?,
               sleepMode: Bool, model: AppModel) {
        stop()
        // Same "one audio source at a time" invariant as the full-screen
        // player's `model.audio.stop()`, from the opposite direction: a
        // floating PiP video is still audio, so starting the list queue has to
        // silence it too, or the two players' `NowPlayingManager`s stomp each
        // other's lock-screen info.
        model.pip.stopFloating()
        guard videos.indices.contains(startIndex) else { return }
        self.model = model
        self.scope = scope
        self.sleepAfterCurrent = sleepMode
        navigator = QueueNavigator(
            videos: videos, startIndex: startIndex, randomize: model.randomize(for: scope),
            isPlayable: { [weak model] video in
                guard let model else { return false }
                return PlaybackSource.isPlayable(video, model: model)
            }
        )
        DevLog.event(.play, "audio start", [
            "video_id": "\(videos[startIndex].id)",
            "count": "\(videos.count)",
            "scope": scope ?? "-",
            "sleep": "\(sleepMode)",
        ])
        startGeneration += 1
        let generation = startGeneration
        Task {
            await model.streamProxy.ensureRunning()
            // A newer start()/stop() ran while we were awaiting — that call
            // owns state and cleanup now, so bail out without touching
            // anything (in particular: never call stop() here).
            guard self.startGeneration == generation else { return }
            guard let video = navigator?.currentVideo,
                  let (item, source) = PlaybackSource.item(for: video, model: model) else {
                DevLog.event(.play, "audio start found no source", [:])
                stop()
                return
            }
            activateAudioSession()
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            self.player = player
            currentID = video.id
            loadingID = nil
            observe(player: player)
            bindPlayToEnd()
            nowPlaying.onNext = { [weak self] in self?.advance(by: 1) }
            nowPlaying.onPrevious = { [weak self] in self?.handlePrevious() }
            nowPlaying.attach(player: player, title: video.title ?? video.url)
            nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
            DevLog.event(.play, "audio source -> \(source)", ["video_id": "\(video.id)"])
            player.play()
        }
    }

    /// Take over the full-screen player's live `AVPlayer` on dismiss, without
    /// rebuilding anything.
    ///
    /// The rebuild this replaces was audible: `start()` drops the audio
    /// session, builds a fresh `AVPlayerItem`, activates the session again,
    /// seeks and waits for the new item to buffer — a gap of anywhere from a
    /// fraction of a second to several, right where the user expects the sound
    /// to carry on. Nothing about the item actually changes when the video
    /// layer goes away (an `AVPlayer` with no layer simply renders no frames,
    /// which is this whole class's premise), so the already-buffered,
    /// already-playing player is carried straight across instead.
    ///
    /// The caller keeps the audio session active and leaves the player's rate
    /// alone: `observe(player:)` seeds `isPlaying` from whatever it is, so a
    /// video paused at dismiss hands back a paused bar. Unlike `start()` this
    /// never calls `pip.stopFloating()` — a float *is* the handoff that
    /// `shouldReturnToAudio` refuses, so there can be none here, and
    /// deactivating a session on its behalf would silence the very player
    /// being adopted.
    func adopt(player: AVPlayer, videos: [Video], startIndex: Int, scope: String?,
               sleepMode: Bool, model: AppModel) {
        // Drops any previous queue and cancels an in-flight `start()`, but
        // must not touch the audio session the incoming player is using.
        stop(deactivatingSession: false)
        guard videos.indices.contains(startIndex) else { return }
        let video = videos[startIndex]
        self.model = model
        self.scope = scope
        self.sleepAfterCurrent = sleepMode
        navigator = QueueNavigator(
            videos: videos, startIndex: startIndex, randomize: model.randomize(for: scope),
            isPlayable: { [weak model] video in
                guard let model else { return false }
                return PlaybackSource.isPlayable(video, model: model)
            }
        )
        self.player = player
        player.allowsExternalPlayback = true
        currentID = video.id
        loadingID = nil
        observe(player: player)
        bindPlayToEnd()
        nowPlaying.onNext = { [weak self] in self?.advance(by: 1) }
        nowPlaying.onPrevious = { [weak self] in self?.handlePrevious() }
        nowPlaying.attach(player: player, title: video.title ?? video.url)
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
        DevLog.event(.play, "audio adopted player", [
            "video_id": "\(video.id)",
            "count": "\(videos.count)",
            "scope": scope ?? "-",
            "sleep": "\(sleepMode)",
            "secs": "\(Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0))",
            "playing": "\(player.timeControlStatus != .paused)",
        ])
    }

    /// Row tap on the current item, and the lock screen's play/pause.
    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    /// The mini-player bar's next/previous buttons — same moves as the lock
    /// screen's, exposed for a caller with no `MPRemoteCommand` involved.
    func skipForward() { advance(by: 1) }
    func skipBackward() { handlePrevious() }

    /// The mini-player bar's thumbnail/title tap: hand the current item to
    /// the full-screen player at the same position audio was at, via the same
    /// restore mechanism the floating PiP button's own restore uses. `model`
    /// is nil only if nothing is playing, which the bar already guards for.
    func openFullScreen() {
        guard let model, let video = navigator?.currentVideo else { return }
        let secs = player?.currentTime().seconds ?? 0
        model.pip.restoreFullScreen(
            video: video, queueSnapshot: navigator?.videos ?? [video], sleepMode: sleepAfterCurrent,
            startSecs: secs.isFinite ? secs : 0, scope: scope, randomize: model.randomize(for: scope)
        )
    }

    /// Tear everything down: pause, drop observers, clear Now Playing, release
    /// the audio session so other apps resume.
    ///
    /// `deactivatingSession: false` is for `adopt`, the one caller that is
    /// clearing this queue in order to keep playing through another player on
    /// the same, still-active session.
    func stop(deactivatingSession: Bool = true) {
        startGeneration += 1
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
            self.playToEndObserver = nil
        }
        rateObservation = nil
        player?.pause()
        player = nil
        navigator = nil
        currentID = nil
        loadingID = nil
        isPlaying = false
        sleepAfterCurrent = false
        nowPlaying.detach()
        if deactivatingSession { deactivateAudioSession() }
    }

    private func observe(player: AVPlayer) {
        rateObservation = player.observe(\.timeControlStatus) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.isPlaying = observed.timeControlStatus != .paused
            }
        }
        isPlaying = player.timeControlStatus != .paused
    }

    /// `model.autoplay` is read at fire time — a closure-captured copy would go
    /// stale the moment the user flips the toolbar switch mid-queue.
    private func bindPlayToEnd() {
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                switch playbackEndAction(
                    autoplay: model.autoplay(for: self.scope),
                    isForeground: UIApplication.shared.applicationState == .active,
                    sleepMode: self.sleepAfterCurrent
                ) {
                case .advance:
                    self.advance(by: 1)
                case .sleep:
                    self.stop()
                    self.runBlackScreenShortcut()
                // Nothing is presented, so there is nothing to dismiss: both
                // non-advancing outcomes end playback where it is.
                case .dismiss, .stop:
                    self.stop()
                }
            }
        }
    }

    /// The mini-player bar's shuffle toggle writes `model.randomizeByFeed`
    /// while the queue is already running, so the navigator's mode is synced at
    /// step time rather than captured in `start()` — same reason
    /// `bindPlayToEnd` reads `model.autoplay(for:)` at fire time.
    private func syncRandomize() {
        guard let model else { return }
        navigator?.setRandomize(model.randomize(for: scope))
    }

    private func advance(by direction: Int) {
        guard let player, let model, navigator != nil else { return }
        syncRandomize()
        guard let nextIndex = navigator?.step(direction: direction),
              let video = navigator?.currentVideo,
              let (item, source) = PlaybackSource.item(for: video, model: model) else {
            DevLog.event(.play, "audio advance found nothing playable", [
                "direction": "\(direction)",
            ])
            stop()
            return
        }
        _ = nextIndex
        currentID = video.id
        player.replaceCurrentItem(with: item)
        bindPlayToEnd()
        nowPlaying.updateTitle(video.title ?? video.url)
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
        DevLog.event(.play, "audio advance -> \(source)", ["video_id": "\(video.id)"])
        player.play()
    }

    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current item; otherwise go back one.
    private func handlePrevious() {
        guard let player else { return }
        syncRandomize()
        if player.currentTime().seconds > 3 || navigator?.isAtQueueStart != false {
            player.seek(to: .zero)
        } else {
            advance(by: -1)
        }
    }

    /// Sleep end-action: hand off to the user's "black-screen" iOS Shortcut,
    /// the same URL the full-screen player opens.
    private func runBlackScreenShortcut() {
        guard let url = URL(string: "shortcuts://run-shortcut?name=black-screen") else { return }
        UIApplication.shared.open(url)
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal — leave local playback running.
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal.
        }
    }
}
