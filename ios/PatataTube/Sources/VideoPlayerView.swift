// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit

struct VideoPlayerView: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                if value.translation.height > 80 { dismiss() }
                            }
                    )
            } else {
                ProgressView().tint(.white)
            }
        }
        .task { setup() }
        .onDisappear { player?.pause() }
    }

    private func setup() {
        let url: URL?
        if model.cache.state(for: video.id) == .cached {
            url = model.cache.localURL(for: video.id)
        } else {
            url = model.streamURL(for: video)
        }
        guard let url else { return }
        let player = AVPlayer(url: url)
        self.player = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in dismiss() }
    }
}
