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
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: () async -> Bool
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
                    if video.previewUrl != nil || cachedPreviewURL != nil {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL)
                            .clipped()
                    }
                    if video.status != "done" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
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
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
                .transition(.scale.combined(with: .opacity))
        case .downloading:
            ProgressView().controlSize(.regular)
                .frame(width: 44, height: 44)
        case .notCached:
            Button {
                Task {
                    withAnimation { downloadPhase = .loading }
                    let ok = await onDownload()
                    withAnimation { downloadPhase = ok ? .done : .idle }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }
}
