// ios/PatataTube/Sources/EpisodesView.swift
import SwiftUI
import PatataTubeKit

/// Episode list for one show, sectioned by season.
struct EpisodesView: View {
    let show: ShowGroup
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) async -> Bool
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
            Button {
                onPlay(episode, show.episodes)
            } label: {
                HStack(spacing: 12) {
                    AuthedImage(
                        path: episode.previewUrl,
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id)
                    )
                    .frame(width: 120, height: 68)
                    .background(.secondary.opacity(0.2))
                    .cornerRadius(6)
                    .clipped()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("E\(episode.episode ?? 0) — \(episode.title ?? "Untitled")")
                            .font(.subheadline)
                        if let summary = episode.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play episode")

            DownloadButton(
                identity: DownloadButtonIdentity(
                    videoID: episode.id,
                    versionID: episode.chosenVersionId,
                    audioLanguage: episode.audioLang
                ),
                currentCacheState: {
                    model.cache.state(
                        for: episode.id,
                        versionId: episode.chosenVersionId
                    )
                },
                onDownload: { await onDownload(episode) },
                onCancel: {
                    model.cache.cancel(
                        id: episode.id,
                        versionId: episode.chosenVersionId
                    )
                }
            )
        }
    }
}
