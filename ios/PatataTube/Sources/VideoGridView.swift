// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    @State private var classifications: [String] = ["children", "adults", "education", "tv", "movies"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var showDownloads = false
    /// Queue snapshot + start index, built at tap time. A single cover item —
    /// presenting from separate state raced the boot load and could hand the
    /// player an empty queue on the first cold-launch tap (index crash).
    @State private var playing: PlaybackQueue?
    @State private var preparationTracker = VideoPreparationTracker()
    @State private var downloadingAll = false
    @State private var errorBannerOffset: CGFloat = 0

    // Search: text updates immediately for the field, but filtering only
    // applies 0.5s after the user stops typing (debounce), to avoid
    // re-filtering the grid on every keystroke.
    @State private var searchText = ""
    @State private var activeSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    // Grid cell size, adjustable via +/- buttons. Persisted across launches.
    @AppStorage("gridCellSize") private var cellSize: Double = 220
    private let minCellSize: Double = 120
    private let maxCellSize: Double = 420
    private let cellSizeStep: Double = 50

    static func shouldDismissErrorBanner(translation: CGSize) -> Bool {
        abs(translation.width) >= 100 && abs(translation.width) > abs(translation.height)
    }

    static func shouldClearErrorBanner(currentText: String?, displayedText: String) -> Bool {
        currentText == displayedText
    }

    static func downloadVideo(id: Int, versionID: Int?, videos: [Video]) -> Video? {
        guard let stored = videos.first(where: { $0.id == id }) else { return nil }
        guard let versionID else { return stored.withChosenVersion(nil) }
        return stored.versions.contains(where: { $0.id == versionID })
            ? stored.withChosenVersion(versionID)
            : nil
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 16)]
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private var filteredVideos: [Video] {
        guard !activeSearch.isEmpty else { return store.videos }
        let query = normalized(activeSearch)
        return store.videos.filter { video in
            if let title = video.title, normalized(title).contains(query) { return true }
            if let showTitle = video.showTitle, normalized(showTitle).contains(query) { return true }
            if let summary = video.summary, normalized(summary).contains(query) { return true }
            if video.versions.contains(where: { normalized($0.label ?? "").contains(query) }) { return true }
            if let filename = video.sourceFilename, normalized(filename).contains(query) { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                filterTabs
                if store.filter == "tv" {
                    ShowsView(
                        videos: filteredVideos,
                        onPlay: { video, queue in
                            play(video, queueSnapshot: queue)
                        },
                        onDownload: { await download($0) }
                    )
                } else if store.filter == "movies" {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredVideos) { video in
                            MovieCell(
                                video: video,
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                            )
                        }
                    }
                    .padding()
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredVideos) { video in
                            let cache = model.cache
                            let videoId = video.id
                            let versionId = video.chosenVersionId
                            VideoCell(
                                video: video,
                                cacheState: cache.state(for: videoId, versionId: versionId),
                                currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl),
                                localFileURL: cache.localURL(for: videoId, versionId: versionId),
                                classifications: classifications,
                                onPlay: { play(video) },
                                onPlaySleep: { play(video, sleepMode: true) },
                                onDownload: { await download(video) },
                                onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                                onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) },
                                onClassify: { c in Task { await store.classify(id: video.id, to: c) } },
                                onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                                onDelete: { Task { await store.delete(id: video.id) } }
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationDestination(for: Video.self) { pushed in
                MovieDetailView(video: pushed,
                                onPlay: { play($0) },
                                onDownload: { await download($0) })
            }
            .navigationDestination(isPresented: $showDownloads) {
                DownloadsView(
                    active: { model.cache.activeDownloads() },
                    recent: { model.cache.recentDownloads() },
                    video: { id, versionID in
                        Self.downloadVideo(id: id, versionID: versionID, videos: store.videos)
                    },
                    onCancel: { activity in
                        model.cache.cancel(id: activity.videoID, versionId: activity.versionID)
                    },
                    onPlay: { video in play(video) }
                )
            }
            .navigationTitle("PatataTube")
            .searchable(text: $searchText, prompt: "Search videos")
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    activeSearch = newValue
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showUpload = true
                        } label: { Label("New video", systemImage: "plus") }

                        Button {
                            Task { await store.refreshLibrary() }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.isLoading)

                        Toggle(isOn: $model.autoplay) {
                            Label("Autoplay", systemImage: "play.circle")
                        }

                        Divider()

                        Button {
                            Task { await downloadAll() }
                        } label: { Label("Download all", systemImage: "arrow.down.circle") }
                        .disabled(downloadingAll)

                        Button {
                            showDownloads = true
                        } label: {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }

                        Button {
                            cellSize = max(cellSize - cellSizeStep, minCellSize)
                        } label: { Label("Smaller cells", systemImage: "minus.magnifyingglass") }
                        .disabled(cellSize <= minCellSize)

                        Button {
                            cellSize = min(cellSize + cellSizeStep, maxCellSize)
                        } label: { Label("Bigger cells", systemImage: "plus.magnifyingglass") }
                        .disabled(cellSize >= maxCellSize)

                        Divider()

                        Button {
                            showSettings = true
                        } label: { Label("Settings", systemImage: "gear") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable { await store.load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showUpload) { UploadView() }
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode)
            }
            .task { await initialLoad() }
            .overlay { if let error = store.errorText { errorBanner(error) } }
        }
        .environment(preparationTracker)
    }
    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                tab(title: "all", value: nil)
                ForEach(classifications, id: \.self) { c in tab(title: c, value: c) }
            }
            .padding(.horizontal)
        }
    }

    private func tab(title: String, value: String?) -> some View {
        Button(title) {
            store.filter = value
            Task { await store.load() }
        }
        .buttonStyle(.borderedProminent)
        .tint(store.filter == value ? .accentColor : .gray)
    }

    private func initialLoad() async {
        let api = APIClient(store: model.credentials)
        if let list = try? await api.classifications() { classifications = list }
        await store.bootLoad()
        // Footprint after the list lands: correlates library size + in-flight
        // downloads with the OOM watchdog kills (PATATATUBE-6, -2).
        MemoryProbe.snapshot("grid-loaded", extra: [
            "video_count": store.videos.count,
            "active_downloads": model.cache.activeDownloads().count,
        ])
    }

    private func play(_ video: Video, sleepMode: Bool = false) {
        let queueSnapshot = filteredVideos
        play(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
    }

    private func play(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
            return
        }
        guard video.isLibrary, video.status != "done" else {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
            return
        }
        Task {
            do {
                guard let readyVideo = try await preparationTracker.trackIfIdle(
                    videoID: video.id,
                    operation: {
                        try await store.ensureReady(id: video.id)
                    }
                ) else {
                    return
                }
                startPlayback(
                    readyVideo,
                    queueSnapshot: queueSnapshot,
                    sleepMode: sleepMode
                )
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    /// Starts playback from the tap-time queue snapshot. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    private func startPlayback(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        playing = PlaybackQueue(video: video, queueSnapshot: queueSnapshot, sleepMode: sleepMode)
    }

    /// Downloads a video for offline playback. Returns true only when the MP4
    /// actually landed on disk, so the caller's checkmark reflects reality.
    @discardableResult
    private func download(_ video: Video) async -> Bool {
        var target = video
        if video.isLibrary, video.status != "done" {
            do {
                target = try await preparationTracker.track(videoID: video.id) {
                    try await store.ensureReady(id: video.id)
                }
            } catch {
                store.errorText = String(describing: error)
                return false
            }
        }
        guard let url = model.streamURL(for: target) else {
            store.errorText = "No server URL configured"
            return false
        }
        let preview = resolveImageURL(target.previewUrl)
        let posterKey = target.showPreviewUrl
        let poster = resolveImageURL(posterKey)
        do {
            try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                           showPosterKey: posterKey, showPoster: poster,
                                           bearerToken: model.credentials.token,
                                           streamCount: model.downloadStreamCount)
            return true
        } catch {
            if isCancellation(error) { return false }
            store.errorText = "Download failed: \(error)"
            return false
        }
    }

    /// Absolute URL for a server image path; absolute URLs pass through.
    private func resolveImageURL(_ path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        guard let base = model.credentials.baseURL else { return nil }
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmedPath, relativeTo: base.appendingPathComponent("/"))
    }

    private func isCancellation(_ error: Error) -> Bool {
        VideoStore.isCancellation(error)
    }

    /// Downloads every not-yet-cached video currently in view (respects the active filter).
    private func downloadAll() async {
        downloadingAll = true
        defer { downloadingAll = false }
        // Snapshot the not-cached targets, then let them run concurrently — the
        // CacheManager gate bounds how many actually download at once.
        let targets = store.videos.filter {
            model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .notCached
        }
        await withTaskGroup(of: Void.self) { group in
            for video in targets {
                group.addTask { await download(video) }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .padding()
                .background(.red.opacity(0.85))
                .foregroundStyle(.white)
                .cornerRadius(8)
                .offset(x: errorBannerOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            errorBannerOffset = value.translation.width
                        }
                        .onEnded { value in
                            if Self.shouldDismissErrorBanner(translation: value.translation),
                               Self.shouldClearErrorBanner(currentText: store.errorText, displayedText: text) {
                                store.errorText = nil
                            }
                            withAnimation(.spring()) {
                                errorBannerOffset = 0
                            }
                        }
                )
                .padding()
        }
    }
}
