// ios/PatataTube/Sources/ShowsView.swift
import SwiftUI
import PatataTubeKit

/// Grid of TV shows; tap navigates to that show's episodes.
struct ShowsView: View {
    let videos: [Video]
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) async -> Bool
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(ShowGroup.group(videos)) { show in
                NavigationLink(value: show) {
                    VStack(alignment: .leading, spacing: 6) {
                        AuthedImage(path: show.posterPath,
                                    localFileURL: cachedPosterURL(for: show),
                                    onNetworkLoad: { data in backfillPoster(data, for: show) })
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(8)
                        Text(show.title).font(.subheadline).lineLimit(2)
                        Text("\(show.episodes.count) episodes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .navigationDestination(for: ShowGroup.self) { show in
            EpisodesView(show: show, onPlay: onPlay, onDownload: onDownload)
        }
    }

    private func cachedPosterURL(for show: ShowGroup) -> URL? {
        model.cache.cachedShowPosterURL(for: show.id)
    }

    private func backfillPoster(_ data: Data, for show: ShowGroup) {
        guard show.posterPath != nil,
              model.cache.cachedShowPosterURL(for: show.id) == nil else { return }
        model.cache.storeShowPoster(data, for: show.id)
    }
}
