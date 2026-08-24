// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit
import UIKit

struct VideoPlayerView: View {
    let videos: [Video]
    let startIndex: Int
    /// Play-and-sleep: play only this item, then run the "black-screen" iOS Shortcut.
    let sleepMode: Bool
    /// When true, "next" (manual skip and autoplay-on-end) draws from a
    /// shuffled, no-immediate-repeat order instead of the sequential list.
    let randomize: Bool
    /// Where to start the *first* item, in seconds. Only ever non-zero when the
    /// user chose "Resume" in the grid's prompt — every later item in the queue
    /// starts at 0.
    let startSecs: Double
    /// Restoration only: seek to `startSecs`, then wait for a tap instead of
    /// playing. Applies to the first item only — auto-advance always plays.
    let startPaused: Bool
    /// Feed/show scope this queue came from, used for its autoplay setting.
    let autoplayScope: String?
    /// True when the audio-only mini player opened this cover. Dismissing then
    /// hands playback back to `AudioQueuePlayer` — same item, same second —
    /// instead of ending the session the user only meant to look at. Carried
    /// per presentation rather than read off `PiPSession` at dismiss time, so a
    /// later grid tap can't inherit an earlier audio tap's flag.
    let returnsToAudio: Bool
    @State private var currentIndex: Int
    /// Queue stepping (sequential/random, playable-only). Seeded in `setup()`
    /// so `playerItem` is available for its playability probe.
    @State private var navigator: QueueNavigator?
    @StateObject private var horizontalLock: HorizontalLockCoordinator
    @StateObject private var orientationControlVisibility = OrientationControlVisibility()

    init(videos: [Video], startIndex: Int, sleepMode: Bool = false,
         randomize: Bool = false, startSecs: Double = 0, startPaused: Bool = false,
         autoplayScope: String? = nil, returnsToAudio: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        self.randomize = randomize
        self.startSecs = startSecs
        self.startPaused = startPaused
        self.autoplayScope = autoplayScope
        self.returnsToAudio = returnsToAudio
        _currentIndex = State(initialValue: startIndex)
        _sleepAfterCurrent = State(initialValue: sleepMode)
        _suppressAutoplayOnce = State(initialValue: startPaused)
        _horizontalLock = StateObject(wrappedValue: HorizontalLockCoordinator())
    }

    private var video: Video { videos[currentIndex] }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    /// Gates mounting the player UI: false until the current item has buffered
    /// enough to play, so we never surface AVKit's crossed-out play button.
    @State private var itemReady = false
    /// KVO on the current item's isPlaybackLikelyToKeepUp; flips itemReady true.
    @State private var readyObserver: NSKeyValueObservation?
    /// Fallback: mount + play even if buffering never reports ready (dead network).
    @State private var readyTimeoutTask: Task<Void, Never>?
    /// Cleared after the first item mounts, so only the restored item starts
    /// paused; every later item in the queue plays as usual.
    @State private var suppressAutoplayOnce: Bool = false
    /// Bumped when the transport controls must be forced visible without a tap
    /// — a restored session mounts paused, and AVKit otherwise leaves the bar
    /// hidden, so nothing on screen says "tap to resume".
    @State private var revealControlsToken = 0
    @State private var nowPlaying = NowPlayingManager()
    @State private var playToEndObserver: NSObjectProtocol?
    /// Periodic time observer that feeds the resume reporter. Removed on dismiss.
    @State private var positionObserver: Any?
    /// KVO for foreground/remote-control pauses. Invalidated before teardown pauses.
    @State private var pauseTransitionObserver: NSKeyValueObservation?
    /// Setup suspends on proxy startup and resume seeking; it must not attach
    /// observers after this presentation has already disappeared.
    @State private var hasDisappeared = false
    /// false while backgrounded: player detached from the video layer so audio continues.
    @State private var attached = true
    /// Captured before suspension so backgrounding never restarts user-paused playback.
    @State private var resumeAfterDetaching = false
    /// Live vertical drag offset for the pull-down-to-dismiss gesture.
    @State private var dragOffset: CGFloat = 0
    /// Runtime sleep intent, seeded from `sleepMode`. When true, the current
    /// video runs the "black-screen" iOS Shortcut at its end instead of
    /// advancing — this wins over the
    /// autoplay toggle (see `playbackEndAction`). Toggled by the in-player moon
    /// button; `sleepMode` stays the immutable launch seed.
    @State private var sleepAfterCurrent: Bool
    /// Records the AVPlayer/AVPlayerItem state machine into DevLog. Inert
    /// without the DEVLOG condition.
    @State private var playbackProbe = PlaybackProbe()
    /// Debug only: identifies one *view identity*. `@State` is created once per
    /// identity, so a repeated id across appear/setup means SwiftUI re-created
    /// this presentation's content; a fresh id means a genuinely new
    /// presentation. That is the discriminator for the re-presenting-player bug.
    @State private var instanceID = String(UUID().uuidString.prefix(8))
    /// The current item played to its end and nothing advanced past it. Only
    /// consulted by the audio handback (`shouldReturnToAudio`), which must not
    /// restart a finished track in the mini player.
    @State private var reachedEnd = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player, itemReady {
                PlayerViewController(
                    player: player,
                    pip: model.pip,
                    attached: attached,
                    resumeAfterDetaching: resumeAfterDetaching,
                    revealControlsToken: revealControlsToken,
                    onPlayerTap: { orientationControlVisibility.reveal() },
                    onSceneAvailable: { horizontalLock.beginPlayerSession(in: $0) }
                )
                    .ignoresSafeArea()
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
            HorizontalLockOverlay(
                isHorizontal: horizontalLock.isHorizontal,
                isVisible: orientationControlVisibility.isVisible,
                isBlocked: false,
                onToggle: {
                    horizontalLock.toggle()
                    orientationControlVisibility.reveal()
                },
                isSleepOn: sleepAfterCurrent,
                onToggleSleep: {
                    sleepAfterCurrent.toggle()
                    orientationControlVisibility.reveal()
                }
            )
        }
        // Home indicator off while playing (YouTube-style); the system still
        // brings it back on touch and hides it again after idle.
        .persistentSystemOverlays(.hidden)
        .simultaneousGesture(pullDownToDismiss)
        .onAppear {
            hasDisappeared = false
            DevLog.event(.nav, "player appear", [
                "video_id": "\(video.id)", "inst": instanceID,
                "start_secs": "\(startSecs)", "start_paused": "\(startPaused)",
            ])
        }
        .task { await setup() }
        .onChange(of: currentIndex) { _, _ in armPictureInPictureHandoff() }
        .onChange(of: sleepAfterCurrent) { _, _ in armPictureInPictureHandoff() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                resumeAfterDetaching = player.map { $0.timeControlStatus != .paused } ?? false
                reportPosition()
            case .background:
                attached = false
            case .active:
                attached = true
                resumeAfterDetaching = false
            default:
                break
            }
        }
        .onDisappear {
            // Handing off to PiP dismisses this cover while the video keeps
            // playing in the float, so the teardown that would kill it —
            // pausing, the audio session, now-playing, the position observer
            // (now owned by `PiPSession`) — is skipped.
            let handingOff = model.pip.isHandingOff
            // Captured before the teardown pauses the player, or a handback
            // would always come back paused.
            let wasPlaying = player?.timeControlStatus != .paused
            let secs = player?.currentTime().seconds ?? 0
            hasDisappeared = true
            orientationControlVisibility.hide()
            horizontalLock.endPlayerSession()
            reportPosition()
            pauseTransitionObserver?.invalidate()
            pauseTransitionObserver = nil
            if !handingOff { player?.pause() }
            removePlayToEndObserver()
            readyObserver?.invalidate()
            readyObserver = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            if !handingOff {
                if let positionObserver { player?.removeTimeObserver(positionObserver) }
                // The staging armed for a PiP that never started now points at
                // an observer this teardown just removed; leaving it would let
                // `stopFloating()` remove it again and throw.
                if let player { model.pip.cancelStaging(for: player) }
                nowPlaying.detach()
                deactivateAudioSession()
            }
            positionObserver = nil
            playbackProbe.detach()
            DevLog.event(.nav, handingOff ? "player handed to pip" : "player dismissed",
                         ["video_id": "\(video.id)", "inst": instanceID])
            // Last, after the teardown above has released the audio session:
            // `AudioQueuePlayer.start` takes its own, and a deactivation
            // running behind it would silence the queue it just started.
            if shouldReturnToAudio(cameFromAudio: returnsToAudio,
                                   isHandingOff: handingOff, reachedEnd: reachedEnd) {
                handBackToAudio(atSecs: secs, playing: wasPlaying)
            }
            DevLog.flush()
        }
    }

    /// Resume the audio-only queue where the video left off: same queue
    /// snapshot, the index the player is on now (autoplay may have moved it),
    /// the same second, and paused if the video was paused.
    private func handBackToAudio(atSecs secs: Double, playing wasPlaying: Bool) {
        DevLog.event(.play, "player handed back to audio", [
            "video_id": "\(video.id)", "secs": "\(Int(secs.isFinite ? secs : 0))",
            "playing": "\(wasPlaying)",
        ])
        model.audio.start(
            videos: videos, startIndex: currentIndex, scope: autoplayScope,
            sleepMode: sleepAfterCurrent, model: model,
            startSecs: secs.isFinite ? secs : 0, startPaused: !wasPlaying
        )
    }

    /// PiP is started by AVKit's own button in the transport bar, and AVKit
    /// gives no warning before it happens — so everything the float will need
    /// is kept staged in `PiPSession` from the moment a player exists, and
    /// refreshed whenever the queue moves.
    private func armPictureInPictureHandoff() {
        guard let player else { return }
        model.pip.prepare(
            player: player,
            positionObserver: positionObserver,
            videos: videos,
            index: currentIndex,
            sleepMode: sleepAfterCurrent,
            scope: autoplayScope,
            randomize: randomize,
            onStart: { dismiss() }
        )
    }

    /// Vertical-only drag; horizontal moves (scrubbing) and taps fall through to AVKit controls.
    private var pullDownToDismiss: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                // Only engage on a downward, vertically-dominant drag.
                guard dy > 0, abs(dy) > abs(dx) else { return }
                dragOffset = dy
            }
            .onEnded { value in
                if value.translation.height > 150 {
                    DevLog.event(.nav, "pull-down dismiss", ["video_id": "\(video.id)", "inst": instanceID, "translation": "\(value.translation.height)"])
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }

    private var dragScale: CGFloat { max(1 - dragOffset / 1000, 0.85) }
    private var backdropOpacity: Double { max(1 - dragOffset / 400, 0.4) }

    private func setup() async {
        DevLog.event(.nav, "player setup", [
            "video_id": "\(videos.indices.contains(currentIndex) ? videos[currentIndex].id : -1)",
            "inst": instanceID,
        ])
        // Defensive: a malformed presentation must dismiss, not trap on videos[currentIndex].
        guard videos.indices.contains(currentIndex) else {
            dismiss()
            return
        }
        navigator = QueueNavigator(
            videos: videos, startIndex: currentIndex, randomize: randomize,
            isPlayable: { playerItem(for: $0) != nil }
        )
        activateAudioSession()
        // Before the URL is built, not after it fails: a dead proxy makes
        // `offlineHLSURL` hand out an address nothing answers on, and AVPlayer
        // reports that as a 12s buffer followed by -1004.
        await model.streamProxy.ensureRunning()
        guard Self.canContinueSetup(
            taskIsCancelled: Task.isCancelled, hasDisappeared: hasDisappeared
        ) else {
            deactivateAudioSession()
            return
        }
        guard let (item, source) = playerItemWithSource(for: video) else { return }
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        if let target = Self.seekTarget(startSecs: startSecs) {
            DevLog.event(.play, "resuming", [
                "video_id": "\(video.id)", "secs": "\(Int(startSecs))",
            ])
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard Self.canContinueSetup(
            taskIsCancelled: Task.isCancelled, hasDisappeared: hasDisappeared
        ) else {
            abandonSetup(player: player)
            return
        }
        playbackProbe.attach(item: item, player: player, video: video, source: source)
        playWhenReady(item: item, on: player)
        Task { await applyAudioSelection(item: item, lang: video.audioLang) }
        Task { await applySubtitleSelection(item: item, lang: video.subtitleLang) }
        nowPlaying.onNext = { advance(by: 1) }
        nowPlaying.onPrevious = { handlePrevious() }
        nowPlaying.attach(player: player, title: title(of: video))
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
        bindPlayToEnd()
        guard Self.canContinueSetup(
            taskIsCancelled: Task.isCancelled, hasDisappeared: hasDisappeared
        ) else {
            abandonSetup(player: player)
            return
        }
        bindPauseTransitions(player: player, item: item, videoID: video.id)
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main
        ) { time in
            guard player.timeControlStatus == .playing else { return }
            let id = video.id
            let duration = player.currentItem?.duration.seconds
            let secs = time.seconds
            Task { await model.positions.record(id: id, secs: secs,
                                                duration: duration?.isFinite == true ? duration : nil,
                                                force: false) }
        }
        armPictureInPictureHandoff()
        await model.positions.flushPending()
        await loadArtwork(for: player)
    }

    /// Sub-second offsets aren't worth a seek — they only cost a buffer stall.
    static func seekTarget(startSecs: Double) -> CMTime? {
        guard startSecs >= 1 else { return nil }
        return CMTime(seconds: startSecs, preferredTimescale: 600)
    }

    /// Only an actual pause transition needs an immediate forced write.
    nonisolated static func shouldForceReportPosition(
        for status: AVPlayer.TimeControlStatus
    ) -> Bool {
        status == .paused
    }

    /// A queued pause callback belongs to one queue item, not merely to the
    /// reusable AVPlayer. Both identities must still match before reporting.
    nonisolated static func isSamePauseSession(
        observedVideoID: Int,
        observedItem: AVPlayerItem,
        activeVideoID: Int,
        activeItem: AVPlayerItem?
    ) -> Bool {
        observedVideoID == activeVideoID && observedItem === activeItem
    }

    /// Rebind pause reporting whenever the queue replaces the current item.
    /// Already-queued callbacks from the old binding are rejected by the item
    /// and video identity check inside their main-actor task.
    private func bindPauseTransitions(
        player: AVPlayer,
        item observedItem: AVPlayerItem,
        videoID observedVideoID: Int
    ) {
        pauseTransitionObserver?.invalidate()
        pauseTransitionObserver = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            guard Self.shouldForceReportPosition(for: player.timeControlStatus),
                  player.currentItem === observedItem else { return }
            Task { @MainActor in
                guard self.player === player,
                      !hasDisappeared,
                      Self.isSamePauseSession(
                        observedVideoID: observedVideoID,
                        observedItem: observedItem,
                        activeVideoID: video.id,
                        activeItem: player.currentItem
                      ) else { return }
                reportPosition(force: true)
            }
        }
    }

    /// A canceled or departed SwiftUI task may resume after an `await`, but it
    /// no longer owns a visible player session and must not install observers.
    nonisolated static func canContinueSetup(
        taskIsCancelled: Bool, hasDisappeared: Bool
    ) -> Bool {
        !taskIsCancelled && !hasDisappeared
    }

    /// Release anything setup attached before noticing cancellation. Safe to
    /// call after `onDisappear` has already performed the same teardown.
    private func abandonSetup(player expectedPlayer: AVPlayer) {
        expectedPlayer.pause()
        readyObserver?.invalidate()
        readyObserver = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        removePlayToEndObserver()
        pauseTransitionObserver?.invalidate()
        pauseTransitionObserver = nil
        if let positionObserver { expectedPlayer.removeTimeObserver(positionObserver) }
        positionObserver = nil
        model.pip.cancelStaging(for: expectedPlayer)
        nowPlaying.detach()
        playbackProbe.detach()
        if player === expectedPlayer { player = nil }
        deactivateAudioSession()
    }

    /// Forced write for the moments with no later chance: pause, background,
    /// dismiss, and queue advance.
    private func reportPosition(force: Bool = true) {
        guard let player else { return }
        let id = video.id
        let secs = player.currentTime().seconds
        guard secs.isFinite else { return }
        let duration = player.currentItem?.duration.seconds
        Task { await model.positions.record(id: id, secs: secs,
                                            duration: duration?.isFinite == true ? duration : nil,
                                            force: force) }
    }

    /// Show a spinner until `item` has buffered enough to play, then mount the
    /// player and start. Cancels any prior observer/timeout so requeueing is safe.
    /// A ~12s timeout mounts anyway so a dead network still surfaces AVKit's UI.
    private func playWhenReady(item: AVPlayerItem, on player: AVPlayer) {
        readyObserver?.invalidate()
        readyTimeoutTask?.cancel()
        itemReady = false

        let markReady = { (trigger: String) in
            guard self.player === player, !self.itemReady else { return }
            self.itemReady = true
            DevLog.event(.play, "mounted and playing", [
                "video_id": "\(self.video.id)", "trigger": trigger,
                "paused": "\(self.suppressAutoplayOnce)",
            ])
            if self.suppressAutoplayOnce {
                // Restored session: mounted and seeked, waiting for a tap.
                // Surface the controls right away so the paused frame is
                // obviously resumable.
                self.suppressAutoplayOnce = false
                self.revealControlsToken += 1
                self.orientationControlVisibility.reveal()
            } else {
                player.play()
            }
            self.readyObserver?.invalidate()
            self.readyObserver = nil
            self.readyTimeoutTask?.cancel()
            self.readyTimeoutTask = nil
        }

        // Already buffered (e.g. cached local file): mount without a flash.
        if item.isPlaybackLikelyToKeepUp {
            markReady("already-buffered")
            return
        }

        readyObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in markReady("likelyToKeepUp") }
        }

        readyTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            // Buffering never reported ready. The player mounts anyway, so from
            // the outside this looks like "it just didn't play" — exactly the
            // symptom under investigation.
            DevLog.event(.play, "ready timeout — mounting anyway after 12s", [
                "video_id": "\(self.video.id)",
                "item_status": "\(item.status.rawValue)",
                "buffer_empty": "\(item.isPlaybackBufferEmpty)",
            ])
            markReady("timeout")
        }
    }

    private func playerItem(for video: Video) -> AVPlayerItem? {
        PlaybackSource.item(for: video, model: model, log: false)?.item
    }

    private func playerItemWithSource(for video: Video) -> (item: AVPlayerItem, source: String)? {
        PlaybackSource.item(for: video, model: model)
    }

    private func title(of video: Video) -> String {
        video.title ?? video.sourceFilename ?? "PatataTube"
    }

    /// Sleep end-action: hand off to the user's "black-screen" iOS Shortcut
    /// instead of an in-app overlay. The Shortcut owns whatever "black screen"
    /// means (brightness, lock, etc.); PatataTube just pauses and launches it.
    private func runBlackScreenShortcut() {
        guard let url = URL(string: "shortcuts://run-shortcut?name=black-screen") else { return }
        UIApplication.shared.open(url)
    }

    /// Rebind end-of-item handling to the current item. `applicationState` and
    /// `model.autoplay` are read at fire time — closure-captured copies would be
    /// frozen at bind time.
    private func bindPlayToEnd() {
        removePlayToEndObserver()
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in
                reportPosition()
                switch playbackEndAction(
                    autoplay: model.autoplay(for: autoplayScope),
                    isForeground: UIApplication.shared.applicationState == .active,
                    sleepMode: sleepAfterCurrent
                ) {
                case .advance:
                    advance(by: 1)
                case .dismiss:
                    reachedEnd = true
                    dismiss()
                case .stop:
                    reachedEnd = true
                    player?.pause()
                case .sleep:
                    reachedEnd = true
                    player?.pause()
                    runBlackScreenShortcut()
                }
            }
        }
    }

    /// Switch to the nearest playable video in `direction`; stop at queue
    /// ends (sequential mode) or when nothing playable remains at all
    /// (random mode — otherwise it loops forever via reshuffling).
    private func advance(by direction: Int) {
        reportPosition()
        guard let player else { return }
        let nextIndex = navigator?.step(direction: direction)
        guard let nextIndex, let (item, source) = playerItemWithSource(for: videos[nextIndex]) else {
            DevLog.event(.play, "advance found nothing playable", ["direction": "\(direction)"])
            reachedEnd = true
            player.pause()
            if UIApplication.shared.applicationState == .active { dismiss() }
            return
        }
        reachedEnd = false
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        bindPauseTransitions(player: player, item: item, videoID: videos[nextIndex].id)
        playbackProbe.attach(item: item, player: player, video: videos[nextIndex], source: source)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        Task { await applySubtitleSelection(item: item, lang: videos[nextIndex].subtitleLang) }
        bindPlayToEnd()
        playWhenReady(item: item, on: player)
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(navigator?.peekHasNext() ?? false)
        Task { await loadArtwork(for: player) }
    }

    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current video; otherwise go back one video. In random mode "queue
    /// start" means the cursor is at position 0 of `playbackOrder`.
    private func handlePrevious() {
        guard let player else { return }
        let atQueueStart = navigator?.isAtQueueStart ?? true
        if player.currentTime().seconds > 3 || atQueueStart {
            player.seek(to: .zero)
        } else {
            advance(by: -1)
        }
    }

    private func removePlayToEndObserver() {
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
            self.playToEndObserver = nil
        }
    }

    /// Best-effort lock-screen artwork; controls work without it.
    private func loadArtwork(for expectedPlayer: AVPlayer) async {
        let index = currentIndex
        guard !Task.isCancelled,
              self.player === expectedPlayer,
              let path = video.previewUrl,
              let data = try? await model.api.imageData(path: path),
              !Task.isCancelled,
              self.player === expectedPlayer,
              currentIndex == index else { return }
        nowPlaying.setArtwork(data, for: expectedPlayer)
    }

    /// Selects the audible option matching the server-side language choice.
    /// mp4 assets carry every allowlisted track; HLS already serves only the
    /// chosen one. No match (or no selection group) leaves the default track.
    private func applyAudioSelection(item: AVPlayerItem, lang: String?) async {
        guard let lang,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        let target = normalizedLanguage(lang)
        guard let option = group.options.first(where: { option in
            guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
            return normalizedLanguage(tag) == target
        }) else { return }
        item.select(option, in: group)
    }

    /// Applies the user's stored subtitle choice, if there is one.
    ///
    /// - `nil` (never chosen): does nothing at all, leaving AVKit's own
    ///   auto-select to honour the playlist's DEFAULT=YES/AUTOSELECT=YES and
    ///   the viewer's system captions preference.
    /// - `""` (explicitly off): deselects the legible group, which is the only
    ///   way to beat that same auto-select.
    /// - a language tag: selects the matching option; no match leaves the
    ///   selection untouched.
    ///
    /// Live in-player switching is handled by AVKit's own captions menu, not
    /// this app.
    private func applySubtitleSelection(item: AVPlayerItem, lang: String?) async {
        guard let lang,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        if lang.isEmpty {
            item.select(nil, in: group)
            return
        }
        let target = normalizedLanguage(lang)
        guard let option = group.options.first(where: { option in
            guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
            return normalizedLanguage(tag) == target
        }) else { return }
        item.select(option, in: group)
    }

    /// "spa" (server, ISO 639-2) and "es-419" (asset, BCP-47) both → "es".
    private func normalizedLanguage(_ code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code.lowercased()
        return Locale.LanguageCode(base).identifier(.alpha2) ?? base.lowercased()
    }

    /// A `.playback` session is what lets audio continue in the background and
    /// AVPlayer send full video (not just audio) over AirPlay.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal — leave local playback running.
        }
    }

    /// Release the session on dismiss so other apps' audio can resume.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal.
        }
    }
}
