// ios/PatataTube/Sources/EpisodesView.swift
import Clocks
import SwiftUI
import PatataTubeKit

@MainActor
@Observable
final class EpisodesDownloadAllState {
    private(set) var canDownloadAll = false
    private(set) var isDownloading = false

    func setEligibility(_ value: Bool) {
        canDownloadAll = value
    }

    func setDownloading(_ value: Bool) {
        isDownloading = value
    }
}

/// Episode list for one show, sectioned by season.
struct EpisodesView: View {
    let show: ShowGroup
    let onPlay: (Video, [Video]) -> Void
    let onDownload: (Video) async -> Bool
    private let cacheStateOverride: ((Video) -> CacheState)?

    @EnvironmentObject var model: AppModel
    @Environment(\.continuousClock) private var clock
    @State private var downloadState = EpisodesDownloadAllState()

    init(
        show: ShowGroup,
        onPlay: @escaping (Video, [Video]) -> Void,
        onDownload: @escaping (Video) async -> Bool,
        currentCacheState: ((Video) -> CacheState)? = nil
    ) {
        self.show = show
        self.onPlay = onPlay
        self.onDownload = onDownload
        self.cacheStateOverride = currentCacheState
    }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AutoplayToggle(isOn: $model.autoplay)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { @MainActor in
                        await downloadAll()
                    }
                } label: {
                    if downloadState.isDownloading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(downloadState.isDownloading || !downloadState.canDownloadAll)
                .accessibilityLabel("Download all episodes")
            }
        }
        .task {
            await observeDownloadAllEligibility()
        }
    }

    @MainActor
    static func hasEligibleEpisode(
        in episodes: [Video],
        currentCacheState: (Video) -> CacheState
    ) -> Bool {
        episodes.contains { currentCacheState($0) == .notCached }
    }

    @MainActor
    static func downloadEligibleEpisodes(
        _ episodes: [Video],
        currentCacheState: (Video) -> CacheState,
        onDownload: (Video) async -> Bool
    ) async {
        for episode in episodes {
            guard currentCacheState(episode) == .notCached else { continue }
            _ = await onDownload(episode)
        }
    }

    private func currentCacheState(for episode: Video) -> CacheState {
        if let cacheStateOverride {
            return cacheStateOverride(episode)
        }
        return model.cache.state(
            for: episode.id,
            versionId: episode.chosenVersionId
        )
    }

    private func observeDownloadAllEligibility() async {
        while !Task.isCancelled {
            downloadState.setEligibility(Self.hasEligibleEpisode(
                in: show.episodes,
                currentCacheState: currentCacheState(for:)
            ))
            do {
                try await clock.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    private func downloadAll() async {
        downloadState.setDownloading(true)
        defer {
            downloadState.setEligibility(Self.hasEligibleEpisode(
                in: show.episodes,
                currentCacheState: currentCacheState(for:)
            ))
            downloadState.setDownloading(false)
        }
        await Self.downloadEligibleEpisodes(
            show.episodes,
            currentCacheState: currentCacheState(for:),
            onDownload: onDownload
        )
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
                    currentCacheState(for: episode)
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
