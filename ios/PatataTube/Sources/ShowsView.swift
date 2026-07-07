// ios/PatataTube/Sources/ShowsView.swift
import SwiftUI
import PatataTubeKit

/// Grid of TV shows; tap navigates to that show's episodes.
struct ShowsView: View {
    let videos: [Video]
    let onPlay: (Video) -> Void
    let onDownload: (Video) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(ShowGroup.group(videos)) { show in
                NavigationLink(value: show) {
                    VStack(alignment: .leading, spacing: 6) {
                        AuthedImage(path: show.posterPath)
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
}
