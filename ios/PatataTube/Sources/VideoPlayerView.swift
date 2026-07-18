// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit

struct VideoPlayerView: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var nowPlaying = NowPlayingManager()
    /// false while backgrounded: player detached from the video layer so audio continues.
    @State private var attached = true
    /// Live vertical drag offset for the pull-down-to-dismiss gesture.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player {
                PlayerViewController(player: player, attached: attached)
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
            case .background:
                attached = false
                player?.play()   // keep audio rolling without the video layer
            case .active:
                attached = true
            default:
                break
            }
        }
        .onDisappear {
            player?.pause()
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
        let player: AVPlayer
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            // Offline MP4 wins: instant, no network. (HLS offline is a later phase.)
            player = AVPlayer(url: model.cache.localURL(for: video.id, versionId: video.chosenVersionId))
        } else if let hlsURL = model.hlsURL(for: video) {
            // Remote HLS exposes native subtitle tracks in the AVKit controls.
            player = AVPlayer(playerItem: AVPlayerItem(asset: authedAsset(url: hlsURL)))
        } else if let url = model.streamURL(for: video) {
            // Direct MP4 fallback for rows without an HLS package.
            player = AVPlayer(playerItem: AVPlayerItem(asset: authedAsset(url: url)))
        } else {
            return
        }
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        nowPlaying.attach(player: player, title: video.title ?? video.sourceFilename ?? "PatataTube")
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in dismiss() }
        }
        await loadArtwork()
    }

    /// Best-effort lock-screen artwork; controls work without it.
    private func loadArtwork() async {
        guard let path = video.previewUrl,
              let data = try? await model.api.imageData(path: path),
              let image = UIImage(data: data) else { return }
        nowPlaying.setArtwork(image)
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
