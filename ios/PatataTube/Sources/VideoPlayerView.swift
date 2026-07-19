// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit
import UIKit

struct VideoPlayerView: View {
    let videos: [Video]
    let startIndex: Int
    @State private var currentIndex: Int

    init(videos: [Video], startIndex: Int) {
        self.videos = videos
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    private var video: Video { videos[currentIndex] }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var nowPlaying = NowPlayingManager()
    @State private var playToEndObserver: NSObjectProtocol?
    /// false while backgrounded: player detached from the video layer so audio continues.
    @State private var attached = true
    /// Captured before suspension so backgrounding never restarts user-paused playback.
    @State private var resumeAfterDetaching = false
    /// Live vertical drag offset for the pull-down-to-dismiss gesture.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player {
                PlayerViewController(
                    player: player,
                    attached: attached,
                    resumeAfterDetaching: resumeAfterDetaching
                )
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
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
            player?.pause()
            removePlayToEndObserver()
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
        activateAudioSession()
        guard let item = playerItem(for: video) else { return }
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        nowPlaying.onNext = { advance(by: 1) }
        nowPlaying.onPrevious = { handlePrevious() }
        nowPlaying.attach(player: player, title: title(of: video))
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
        bindPlayToEnd()
        await loadArtwork(for: player)
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

    /// Rebind end-of-item handling to the current item. Foreground keeps the
    /// dismiss-on-end behavior; locked/backgrounded always auto-advances.
    /// `applicationState` is read at fire time — a closure-captured scenePhase
    /// would be frozen at bind time.
    private func bindPlayToEnd() {
        removePlayToEndObserver()
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in
                if UIApplication.shared.applicationState == .active {
                    dismiss()
                } else {
                    advance(by: 1)
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

    /// Switch to the nearest playable video in `direction`; stop at queue ends.
    private func advance(by direction: Int) {
        guard let player else { return }
        guard let nextIndex = playableIndex(from: currentIndex, direction: direction),
              let item = playerItem(for: videos[nextIndex]) else {
            player.pause()
            if UIApplication.shared.applicationState == .active { dismiss() }
            return
        }
        currentIndex = nextIndex
        player.replaceCurrentItem(with: item)
        bindPlayToEnd()
        player.play()
        nowPlaying.updateTitle(title(of: video))
        nowPlaying.setNextEnabled(playableIndex(from: currentIndex, direction: 1) != nil)
        Task { await loadArtwork(for: player) }
    }

    /// iOS convention: >3s in (or already at the queue start) restarts the
    /// current video; otherwise go back one video.
    private func handlePrevious() {
        guard let player else { return }
        if player.currentTime().seconds > 3 || playableIndex(from: currentIndex, direction: -1) == nil {
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
