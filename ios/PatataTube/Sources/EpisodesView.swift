// ios/PatataTube/Sources/EpisodesView.swift
import SwiftUI
import PatataTubeKit

/// Episode list for one show, sectioned by season.
struct EpisodesView: View {
    let show: ShowGroup
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(show.seasons(), id: \.number) { season in
                Section("Season \(season.number)") {
                    ForEach(season.episodes) { episode in
                        row(for: episode)
                    }
                }
            }
        }
        .navigationTitle(show.title)
    }

    private func row(for episode: Video) -> some View {
        HStack(spacing: 12) {
            AuthedImage(path: episode.previewUrl,
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id))
                .frame(width: 120, height: 68)
                .background(.secondary.opacity(0.2))
                .cornerRadius(6)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text("E\(episode.episode ?? 0) — \(episode.title ?? "Untitled")")
                    .font(.subheadline)
                if let summary = episode.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            switch model.cache.state(for: episode.id, versionId: episode.chosenVersionId) {
            case .cached:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading(let p):
                ProgressView(value: p)
            case .notCached:
                Button { onDownload(episode) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay(episode, show.episodes) }
    }
}
