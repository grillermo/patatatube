// ios/PatataTube/Sources/MovieRow.swift
import SwiftUI
import PatataTubeKit

/// One movie as a flat list row. Like `MovieCell` it is only a link — no menu
/// and no download control, because `MovieDetailView` owns those. The poster
/// letterboxes inside the same 78x44 box `VideoRow` uses so titles line up
/// across feeds.
struct MovieRow: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    var cachedPreviewURL: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: Route.movie(id: video.id)) {
                HStack(spacing: 12) {
                    thumbnail
                    Text(video.title ?? video.url)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil || cachedPreviewURL != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                    fill: false,
                                    onNetworkLoad: { data in
                                        guard let path = video.previewUrl,
                                              model.cache.cachedPreviewURL(for: video.id, path: path) == nil else { return }
                                        model.cache.storePreview(data, for: video.id, path: path)
                                    })
                    }
                    .clipped()
            }
        }
        .frame(width: VideoRow.thumbWidth, height: VideoRow.thumbHeight)
        .clipped()
        .cornerRadius(4)
    }
}
