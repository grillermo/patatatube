// ios/PatataTube/Sources/EpisodesView.swift
import Clocks
import SwiftUI
import PatataTubeKit

@MainActor
@Observable
final class EpisodesDownloadAllState {
    private(set) var canDownloadAll = false
    private(set) var isDownloading = false
    /// Confirmation in flight. Held here rather than in `@State` so the whole
    /// Download-all flow has one owner.
    var pendingDownloadAll: DownloadAllRequest?

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
    let onDownload: @MainActor @Sendable (Video) async -> Bool
    private let cacheStateOverride: (@MainActor @Sendable (Video) -> CacheState)?
    /// Pushing Downloads belongs to the stack's owner — this view no longer
    /// declares destinations.
    var showDownloads: () -> Void = {}

    @EnvironmentObject var model: AppModel
    @Environment(\.continuousClock) private var clock
    @Environment(\.scenePhase) private var scenePhase
    @State private var downloadState = EpisodesDownloadAllState()
    @State private var visibleTracker = VisibleItemsTracker()
    @State private var anchorDebounceTask: Task<Void, Never>?

    private var anchorKey: String { RestorationState.showKey(title: show.title) }

    init(
        show: ShowGroup,
        onPlay: @escaping (Video, [Video]) -> Void,
        onDownload: @escaping @MainActor @Sendable (Video) async -> Bool,
        currentCacheState: (@MainActor @Sendable (Video) -> CacheState)? = nil,
        showDownloads: @escaping () -> Void = {}
    ) {
        self.show = show
        self.onPlay = onPlay
        self.onDownload = onDownload
        self.cacheStateOverride = currentCacheState
        self.showDownloads = showDownloads
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(show.seasons(), id: \.number) { season in
                    Section("Season \(season.number)") {
                        ForEach(season.episodes) { episode in
                            row(for: episode)
                                .id(String(episode.id))
                                .onAppear {
                                    visibleTracker.appeared(String(episode.id))
                                    scheduleAnchorSave()
                                }
                                .onDisappear {
                                    visibleTracker.disappeared(String(episode.id))
                                    scheduleAnchorSave()
                                }
                        }
                    }
                }
            }
            .onAppear {
                DevLog.event(.nav, "episodes appear", ["show": show.title])
                visibleTracker.setOrder(show.episodes.map { String($0.id) })
                if let anchor = model.restorationStore.load().scrollAnchors[anchorKey] {
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .onDisappear {
                DevLog.event(.nav, "episodes disappear", ["show": show.title])
            }
        }
        .navigationTitle(show.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Episodes only ever exist under the tv tab, so that's the
                // scope this toggle writes.
                AutoplayToggle(isOn: model.autoplayBinding(for: "tv"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentDownloadAll()
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
        .alert(
            "Download all",
            isPresented: Binding(
                get: { downloadState.pendingDownloadAll != nil },
                set: { if !$0 { downloadState.pendingDownloadAll = nil } }
            ),
            presenting: downloadState.pendingDownloadAll
        ) { request in
            Button("Cancel", role: .cancel) { downloadState.pendingDownloadAll = nil }
            Button("Download") {
                let targets = request.targets
                downloadState.pendingDownloadAll = nil
                // Push Downloads so the confirm lands on the progress list.
                showDownloads()
                Task { @MainActor in await downloadAll(targets) }
            }
        } message: { request in
            Text(VideoGridView.downloadAllMessage(count: request.targets.count, freeBytes: request.freeBytes))
        }
        .task {
            await observeDownloadAllEligibility()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue != .active else { return }
            anchorDebounceTask?.cancel()
            if let topmost = visibleTracker.topmost {
                let key = anchorKey
                model.restorationStore.mutate { $0.scrollAnchors[key] = topmost }
            }
        }
    }

    private func scheduleAnchorSave() {
        let key = anchorKey
        anchorDebounceTask?.cancel()
        anchorDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let topmost = visibleTracker.topmost else { return }
            model.restorationStore.mutate { $0.scrollAnchors[key] = topmost }
        }
    }

    /// Snapshots the not-yet-cached episodes and asks for confirmation, so the
    /// count in the dialog is the work that actually starts.
    private func presentDownloadAll() {
        let targets = show.episodes.filter { currentCacheState(for: $0) == .notCached }
        guard !targets.isEmpty else { return }
        downloadState.pendingDownloadAll = DownloadAllRequest(
            targets: targets,
            freeBytes: DeviceStorage.availableBytes(at: model.cache.cacheRootURL)
        )
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
        limit: Int,
        currentCacheState: @escaping @MainActor @Sendable (Video) -> CacheState,
        onDownload: @escaping @MainActor @Sendable (Video) async -> Bool
    ) async {
        // Eligibility is checked inside the operation, not by pre-filtering:
        // an episode can sit queued in the window long enough to finish
        // downloading by another route, and re-downloading it wastes the slot.
        await withBoundedTaskGroup(limit: limit, over: episodes) { episode in
            guard currentCacheState(episode) == .notCached else { return }
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

    private func downloadAll(_ targets: [Video]) async {
        downloadState.setDownloading(true)
        defer {
            downloadState.setEligibility(Self.hasEligibleEpisode(
                in: show.episodes,
                currentCacheState: currentCacheState(for:)
            ))
            downloadState.setDownloading(false)
        }
        await Self.downloadEligibleEpisodes(
            targets,
            limit: model.cache.maxConcurrentDownloads,
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
                        localFileURL: model.cache.cachedPreviewURL(for: episode.id, path: episode.previewUrl)
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
                },
                onDeleteCache: {
                    model.cache.removeCached(
                        id: episode.id,
                        versionId: episode.chosenVersionId
                    )
                }
            )
        }
    }
}
