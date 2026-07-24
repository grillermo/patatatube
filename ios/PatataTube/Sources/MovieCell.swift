// ios/PatataTube/Sources/MovieCell.swift
import SwiftUI
import PatataTubeKit

/// Portrait 2:3 poster for the "movies" filter tab. Just the artwork as a
/// NavigationLink to MovieDetailView — no chrome, no controls; the detail
/// view owns download/classify/delete.
struct MovieCell: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil

    var body: some View {
        NavigationLink(value: video) {
            ZStack {
                Rectangle().fill(.black)
                Text(video.title ?? video.url)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                if video.previewUrl != nil || cachedPreviewURL != nil {
                    // scaledToFill previews report their covering size as their
                    // frame, which can exceed the cell; sizing the ZStack from the
                    // black rectangle and clipping here keeps every cell 2:3.
                    Rectangle().fill(.clear)
                        .overlay {
                            AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                        onNetworkLoad: { data in
                                            guard let path = video.previewUrl,
                                                  model.cache.cachedPreviewURL(for: video.id, path: path) == nil else { return }
                                            model.cache.storePreview(data, for: video.id, path: path)
                                        })
                        }
                        .clipped()
                }
                if video.status != "done" {
                    Text(video.status).font(.caption).padding(4)
                        .background(.thinMaterial).cornerRadius(4)
                }
            }
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .clipped()
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
