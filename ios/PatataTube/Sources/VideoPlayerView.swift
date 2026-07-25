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
    @State private var currentIndex: Int
    /// Random-mode only: cursor state over a shuffled permutation of
    /// `videos.indices`, grown with a fresh shuffle whenever it's exhausted
    /// going forward. Unused (stays empty) when `randomize` is false.
    @State private var playbackOrder: [Int] = []
    @State private var orderPosition: Int = 0
    @StateObject private var orientationLock: OrientationLockCoordinator
    @StateObject private var orientationControlVisibility = OrientationControlVisibility()

    init(videos: [Video], startIndex: Int, sleepMode: Bool = false, randomize: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        self.randomize = randomize
        _currentIndex = State(initialValue: startIndex)
        _sleepAfterCurrent = State(initialValue: sleepMode)
        _orientationLock = StateObject(wrappedValue: OrientationLockCoordinator())
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
    @State private var nowPlaying = NowPlayingManager()
    @State private var playToEndObserver: NSObjectProtocol?
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player, itemReady {
                PlayerViewController(
                    player: player,
                    attached: attached,
                    resumeAfterDetaching: resumeAfterDetaching,
                    onPlayerTap: { orientationControlVisibility.reveal() },
                    onSceneAvailable: { orientationLock.beginPlayerSession(in: $0) }
                )
                    .ignoresSafeArea()
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
            OrientationLockOverlay(
                isLocked: orientationLock.isLocked,
                isVisible: orientationControlVisibility.isVisible,
                isBlocked: false,
                onToggle: {
                    orientationLock.toggle()
                    orientationControlVisibility.reveal()
                },
                isSleepOn: sleepAfterCurrent,
                onToggleSleep: {
                    sleepAfterCurrent.toggle()
                    orientationControlVisibility.reveal()
                }
            )
        }
        .simultaneousGesture(pullDownToDismiss)
        .task { await setup() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                resumeAfterDetaching = player.map { $0.timeControlStatus != .paused } ?? false
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
            orientationControlVisibility.hide()
            orientationLock.endPlayerSession()
            player?.pause()
            removePlayToEndObserver()
            readyObserver?.invalidate()
            readyObserver = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            nowPlaying.detach()
            deactivateAudioSession()
        }
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
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }

    private var dragScale: CGFloat { max(1 - dragOffset / 1000, 0.85) }
    private var backdropOpacity: Double { max(1 - dragOffset / 400, 0.4) }

    private func setup() async {
        // Defensive: a malformed presentation must dismiss, not trap on videos[currentIndex].
        guard videos.indices.contains(currentIndex) else {
            dismiss()
            return
        }
        if randomize {
            let playable = playableVideoIndices
            let order = shuffledPlaybackOrder(count: playable.count, pinFirst: playable.firstIndex(of: currentIndex))
            playbackOrder = order.map { playable[$0] }
            orderPosition = 0
        }
        activateAudioSession()
        guard let item = playerItem(for: video) else { return }
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        playWhenReady(item: item, on: player)
        Task { await applyAudioSelection(item: item, lang: video.audioLang) }
        nowPlaying.onNext = { advance(by: 1) }
        nowPlaying.onPrevious = { handlePrevious() }
        nowPlaying.attach(player: player, title: title(of: video))
        nowPlaying.setNextEnabled(randomize ? hasAnyPlayableVideo : playableIndex(from: currentIndex, direction: 1) != nil)
        bindPlayToEnd()
        await loadArtwork(for: player)
    }

    /// Show a spinner until `item` has buffered enough to play, then mount the
    /// player and start. Cancels any prior observer/timeout so requeueing is safe.
    /// A ~12s timeout mounts anyway so a dead network still surfaces AVKit's UI.
    private func playWhenReady(item: AVPlayerItem, on player: AVPlayer) {
        readyObserver?.invalidate()
        readyTimeoutTask?.cancel()
        itemReady = false

        let markReady = {
            guard self.player === player, !self.itemReady else { return }
            self.itemReady = true
            player.play()
            self.readyObserver?.invalidate()
            self.readyObserver = nil
            self.readyTimeoutTask?.cancel()
            self.readyTimeoutTask = nil
        }

        // Already buffered (e.g. cached local file): mount without a flash.
        if item.isPlaybackLikelyToKeepUp {
            markReady()
            return
        }

        readyObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in markReady() }
        }

        readyTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            markReady()
        }
    }

    /// AVPlayerItem for a queue entry, or nil when it has no playable source
    /// (skipped during queue navigation). Order matches the original logic:
    /// cached MP4 → remote HLS → direct MP4.
    private func playerItem(for video: Video) -> AVPlayerItem? {
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            // Offline MP4 wins: instant, no network. (HLS offline is a later phase.)
            return AVPlayerItem(url: model.cache.localURL(for: video.id, versionId: video.chosenVersionId))
        }
        // Library rows that haven't been converted server-side have no streamable file yet.
        if video.isLibrary && video.status != "done" { return nil }
        if let hlsURL = model.hlsURL(for: video) {
            // Remote HLS exposes native subtitle tracks in the AVKit controls.
            return AVPlayerItem(asset: authedAsset(url: hlsURL))
        }
        if let url = model.streamURL(for: video) {
            // Direct MP4 fallback for rows without an HLS package.
            return AVPlayerItem(asset: authedAsset(url: url))
        }
        return nil
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
                switch playbackEndAction(
                    autoplay: model.autoplay,
                    isForeground: UIApplication.shared.applicationState == .active,
                    sleepMode: sleepAfterCurrent
                ) {
                case .advance:
                    advance(by: 1)
                case .dismiss:
                    dismiss()
                case .stop:
                    player?.pause()
                case .sleep:
                    player?.pause()
                    runBlackScreenShortcut()
                }
            }
        }
    }

    /// Nearest queue index in `direction` with a playable source, or nil.
    private func playableIndex(from index: Int, direction: Int) -> Int? {
        var i = index + direction
        while videos.indices.contains(i) {
            if playerItem(for: videos[i]) != nil { return i }
            i += direction
        }
        return nil
    }

    /// Whether at least one video in the queue currently has a playable
    /// source — used to decide the lock-screen "next" enabled state in
    /// random mode, where a literal end-of-list peek doesn't apply (the
    /// order reshuffles forever).
    private var hasAnyPlayableVideo: Bool {
        videos.contains { playerItem(for: $0) != nil }
    }

    /// Indices of videos that currently have a playable source — the pool
    /// `playbackOrder` is drawn from and reshuffled over in random mode.
    /// Excluding unplayable entries here (rather than skipping them during
    /// stepping) keeps `orderPosition == 0` an accurate "nothing before me"
    /// check, the same guarantee sequential mode gets from `playableIndex`.
    private var playableVideoIndices: [Int] {
        videos.indices.filter { playerItem(for: videos[$0]) != nil }
    }

    /// Random-mode step: walks `playbackOrder`'s cursor in `direction`.
    /// Forward, grows the order with a fresh reshuffle over the currently
    /// playable pool (excluding the wrap point, so autoplay's loop never
    /// repeats a video back-to-back) whenever the step runs off the end.
    /// Returns the resulting `videos` index, or nil if no playable video
    /// exists to grow into. Advancing forward commits the step (mutates
    /// `orderPosition`/`playbackOrder`); this must only be called when the
    /// caller intends to actually move, never as a peek.
    private func randomStep(direction: Int) -> Int? {
        if direction > 0 {
            let nextPosition = orderPosition + 1
            if nextPosition >= playbackOrder.count {
                let playable = playableVideoIndices
                guard !playable.isEmpty else { return nil }
                let avoidPosition = playbackOrder.last.flatMap { playable.firstIndex(of: $0) }
                playbackOrder += shuffledPlaybackOrder(count: playable.count, avoidFirst: avoidPosition).map { playable[$0] }
            }
            guard nextPosition < playbackOrder.count else { return nil }
            orderPosition = nextPosition
            return playbackOrder[nextPosition]
        } else {
            guard orderPosition > 0 else { return nil }
            orderPosition -= 1
            return playbackOrder[orderPosition]
        }
    }

    /// Switch to the nearest playable video in `direction`; stop at queue
    /// ends (sequential mode) or when nothing playable remains at all
    /// (random mode — otherwise it loops forever via reshuffling).
    private func advance(by direction: Int) {
        guard let player else { return }
        let nextIndex = randomize
            ? randomStep(direction: direction)
            : playableIndex(from: currentIndex, direction: direction)
        guard let nextIndex, let item = playerItem(for: videos[nextIndex]) else {
            player.pause()
            if UIApplication.shared.applicationState == .active { dismiss() }
            return
        }
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        Task { await applyAudioSelection(item: item, lang: videos[nextIndex].audioLang) }
        bindPlayToEnd()
        playWhenReady(item: item, on: player)
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(randomize ? hasAnyPlayableVideo : playableIndex(from: currentIndex, direction: 1) != nil)
        Task { await loadArtwork(for: player) }
    }

    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current video; otherwise go back one video. In random mode "queue
    /// start" means the cursor is at position 0 of `playbackOrder`.
    private func handlePrevious() {
        guard let player else { return }
        let atQueueStart = randomize ? orderPosition == 0 : playableIndex(from: currentIndex, direction: -1) == nil
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

    /// AVURLAsset carrying the bearer token; AVPlayer reuses these headers for
    /// the HLS playlist, segment, and subtitle sub-requests on the same asset.
    private func authedAsset(url: URL) -> AVURLAsset {
        var options: [String: Any] = [:]
        if let token = model.credentials.token {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }
        return AVURLAsset(url: url, options: options)
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
