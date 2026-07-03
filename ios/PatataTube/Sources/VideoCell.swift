// ios/PatataTube/Sources/VideoCell.swift
import SwiftUI
import PatataTubeKit

struct VideoCell: View {
    let video: Video
    let cacheState: CacheState
    let classifications: [String]
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.2))
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                    if let preview = video.previewUrl, let url = URL(string: preview) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { ProgressView() }
                        .clipped()
                    }
                    if video.status != "completed" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)

            Text(video.title ?? video.url).font(.subheadline).lineLimit(1)

            HStack {
                downloadButton
                Spacer()
                Menu {
                    Button("Move up") { onMoveUp() }
                    Button("Move down") { onMoveDown() }
                    Divider()
                    ForEach(classifications, id: \.self) { c in
                        Button(c) { onClassify(c) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
    }

    @ViewBuilder private var downloadButton: some View {
        switch cacheState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let p):
            ProgressView(value: p)
        case .notCached:
            Button(action: onDownload) { Image(systemName: "arrow.down.circle") }
        }
    }
}
