// ios/PatataTube/Sources/ShowsView.swift
import SwiftUI
import PatataTubeKit

/// Grid of TV shows; tap navigates to that show's episodes.
struct ShowsView: View {
    let videos: [Video]
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) -> Void
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
        guard let key = show.posterPath else { return nil }
        return model.cache.cachedShowPosterURL(for: key)
    }

    /// Self-heal shows downloaded before poster caching existed: when the
    /// poster arrives over the network and at least one episode is already
    /// cached, persist it so the next launch works offline.
    private func backfillPoster(_ data: Data, for show: ShowGroup) {
        guard let key = show.posterPath,
              model.cache.cachedShowPosterURL(for: key) == nil,
              show.episodes.contains(where: {
                  model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .cached
              }) else { return }
        model.cache.storeShowPoster(data, for: key)
    }
}
