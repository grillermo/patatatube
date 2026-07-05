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
    let onDownload: () async -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    /// Tracks the button's live transition: idle → loading → done, layered over `cacheState`.
    @State private var downloadPhase: DownloadPhase = .idle

    private enum DownloadPhase { case idle, loading, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                ZStack {
                    Rectangle().fill(.black)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                    Text(video.title ?? video.url)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    if video.status != "completed" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                }
            }
            .buttonStyle(.plain)

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

    /// Local phase wins during the live tap→download→done transition; otherwise trust the parent.
    private var effectiveState: CacheState {
        switch downloadPhase {
        case .loading: return .downloading(0)
        case .done: return .cached
        case .idle: return cacheState
        }
    }

    @ViewBuilder private var downloadButton: some View {
        switch effectiveState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .downloading:
            ProgressView().controlSize(.small)
        case .notCached:
            Button {
                Task {
                    withAnimation { downloadPhase = .loading }
                    await onDownload()
                    withAnimation { downloadPhase = .done }
                }
            } label: { Image(systemName: "arrow.down.circle") }
        }
    }
}
