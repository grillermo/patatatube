// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit

struct VideoPlayerView: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    /// Live vertical drag offset for the pull-down-to-dismiss gesture.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backdropOpacity)
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .offset(y: dragOffset)
                    .scaleEffect(dragScale)
            } else {
                ProgressView().tint(.white)
            }
        }
        .simultaneousGesture(pullDownToDismiss)
        .task { setup() }
        .onDisappear { player?.pause() }
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

    private func setup() {
        let player: AVPlayer
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            player = AVPlayer(url: model.cache.localURL(for: video.id, versionId: video.chosenVersionId))
        } else {
            guard let url = model.streamURL(for: video) else { return }
            var options: [String: Any] = [:]
            if let token = model.credentials.token {
                options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
            }
            let asset = AVURLAsset(url: url, options: options)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        self.player = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in dismiss() }
    }
}
