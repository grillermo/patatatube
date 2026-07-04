// ios/PatataTube/Sources/VideoCell.swift
import SwiftUI
import PatataTubeKit

struct VideoCell: View {
    let video: Video
    let cacheState: CacheState
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil
    let classifications: [String]
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.2))
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                    if let url = previewURL {
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
                    Divider()
                    Button("Delete video", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Cached local preview wins so it renders while offline; fall back to remote.
    private var previewURL: URL? {
        cachedPreviewURL ?? video.previewUrl.flatMap(URL.init(string:))
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
