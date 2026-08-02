// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

/// Confirmation payload for Download all. Carries the snapshot the dialog
/// describes so the count shown and the work started cannot drift apart.
struct DownloadAllRequest: Identifiable {
    let id = UUID()
    let targets: [Video]
    let freeBytes: Int64?
}

/// A play tap parked behind the resume prompt.
struct PendingResume: Identifiable {
    let id: Int
    let video: Video
    let queueSnapshot: [Video]
    let sleepMode: Bool
    let secs: Double
}

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    @State private var classifications: [String] = ["children", "adults", "education", "tv", "movies"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var showDownloads = false
    @State private var showWebBridge = false
    /// Queue snapshot + start index, built at tap time. A single cover item —
    /// presenting from separate state raced the boot load and could hand the
    /// player an empty queue on the first cold-launch tap (index crash).
    @State private var playing: PlaybackQueue?
    /// Set when a tv/movies tap has a resume point worth asking about; the
    /// alert below turns it into either a seek or a fresh start.
    @State private var pendingResume: PendingResume?
    @State private var preparationTracker = VideoPreparationTracker()
    @State private var downloadingAll = false
    @State private var pendingDownloadAll: DownloadAllRequest?
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

    static func downloadAllMessage(count: Int, freeBytes: Int64?) -> String {
        let videos = count == 1 ? "1 video" : "\(count) videos"
        guard let freeBytes else {
            return "Download \(videos) to this iPad?"
        }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "Download \(videos) to this iPad? \(free) free."
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
                if store.isLoading && filteredVideos.isEmpty {
                    if store.filter == "tv" || store.filter == "movies" {
                        SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                                     showsTextBars: store.filter == "tv")
                    } else {
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0)
                    }
                } else if store.filter == "tv" {
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
            .navigationBarTitleDisplayMode(.inline)
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
                ToolbarItem(placement: .principal) {
                    filterTabs
                }
                // Pin the search field ahead of the menu so the ellipsis sits
                // to its right. Without this the system appends search last
                // and the menu ends up on the far side of the bar.
                // iOS 26+ only; older systems keep the default ordering.
                if #available(iOS 26.0, *) {
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
            .onChange(of: model.webBridgeRequests) { _, _ in showWebBridge = true }
            .refreshable { await store.refreshLibrary() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showUpload) { UploadView() }
            .fullScreenCover(isPresented: $showWebBridge) { WebBridgeView() }
            .alert(
                "Download all",
                isPresented: Binding(
                    get: { pendingDownloadAll != nil },
                    set: { if !$0 { pendingDownloadAll = nil } }
                ),
                presenting: pendingDownloadAll
            ) { request in
                Button("Cancel", role: .cancel) { pendingDownloadAll = nil }
                Button("Download") {
                    let targets = request.targets
                    pendingDownloadAll = nil
                    // Push Downloads so the confirm lands on the progress list.
                    showDownloads = true
                    Task { await runDownloadAll(targets) }
                }
            } message: { request in
                Text(Self.downloadAllMessage(count: request.targets.count, freeBytes: request.freeBytes))
            }
            .alert(
                "Resume playback",
                isPresented: Binding(
                    get: { pendingResume != nil },
                    set: { if !$0 { pendingResume = nil } }
                ),
                presenting: pendingResume
            ) { request in
                Button("Resume from \(ResumeDecision.timestamp(request.secs))") {
                    pendingResume = nil
                    begin(request.video, queueSnapshot: request.queueSnapshot,
                          sleepMode: request.sleepMode, startSecs: request.secs)
                }
                Button("Play from start") {
                    pendingResume = nil
                    begin(request.video, queueSnapshot: request.queueSnapshot,
                          sleepMode: request.sleepMode, startSecs: 0)
                }
                Button("Cancel", role: .cancel) { pendingResume = nil }
            } message: { request in
                Text("You stopped at \(ResumeDecision.timestamp(request.secs)).")
            }
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode,
                                randomize: model.randomize(for: store.filter),
                                startSecs: request.startSecs)
            }
            .task { await initialLoad() }
            .overlay { if let error = store.errorText { errorBanner(error) } }
        }
        .environment(preparationTracker)
    }

    /// Segmented control over the classifications. `""` stands in for a nil
    /// filter so the picker has a non-optional selection; it is never offered
    /// as a segment, it only keeps the control in a valid state before the
    /// first filter lands.
    private var filterBinding: Binding<String> {
        Binding(
            get: { store.filter ?? "" },
            set: { newValue in
                guard newValue != store.filter else { return }
                Task { await store.switchFilter(to: newValue) }
            }
        )
    }

    private var filterTabs: some View {
        Picker("Classification", selection: filterBinding) {
            ForEach(classifications, id: \.self) { c in
                Text(c.capitalized).tag(c)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                showUpload = true
            } label: { Label("New video", systemImage: "plus") }

            Toggle(isOn: $model.autoplay) {
                Label("Autoplay", systemImage: "play.circle")
            }

            Toggle(isOn: model.randomizeBinding(for: store.filter)) {
                Label("Randomize", systemImage: "shuffle")
            }

            Divider()

            Button {
                presentDownloadAll()
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
    /// tv/movies rows with real progress stop here and ask first.
    private func startPlayback(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false) {
        let secs = model.resumeStore.resolved(server: video.resumeSecs, for: video.id)
        switch ResumeDecision.decide(resumeSecs: secs, classification: video.classification) {
        case .ask(let secs):
            pendingResume = PendingResume(
                id: video.id,
                video: video,
                queueSnapshot: queueSnapshot,
                sleepMode: sleepMode,
                secs: secs
            )
        case .playFromStart:
            begin(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, startSecs: 0)
        }
    }

    private func begin(
        _ video: Video,
        queueSnapshot: [Video],
        sleepMode: Bool,
        startSecs: Double
    ) {
        playing = PlaybackQueue(
            video: video,
            queueSnapshot: queueSnapshot,
            sleepMode: sleepMode,
            startSecs: startSecs
        )
    }

    /// Downloads a video for offline playback. Returns true only when the MP4
    /// actually landed on disk, so the caller's checkmark reflects reality.
    @discardableResult
    private func download(_ video: Video, bulk: Bool = false) async -> Bool {
        var target = video
        if video.isLibrary, video.status != "done" {
            do {
                target = try await preparationTracker.track(videoID: video.id) {
                    try await store.ensureReady(id: video.id, bulk: bulk)
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
            if let master = model.hlsURL(for: target), target.hlsPath?.isEmpty == false {
                try await model.cache.downloadHLS(
                    id: target.id, versionId: target.chosenVersionId,
                    masterURL: master,
                    preview: preview, showPosterKey: posterKey, showPoster: poster,
                    bearerToken: model.credentials.token
                )
            } else {
                try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                               showPosterKey: posterKey, showPoster: poster,
                                               bearerToken: model.credentials.token,
                                               streamCount: model.downloadStreamCount)
            }
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

    /// Collects the not-yet-cached videos currently on screen and asks for
    /// confirmation. Filters `filteredVideos`, not `store.videos`: the grid
    /// renders the search-filtered list, and a dialog announcing a count has to
    /// match what the user is looking at.
    private func presentDownloadAll() {
        let targets = filteredVideos.filter {
            model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .notCached
        }
        guard !targets.isEmpty else { return }
        pendingDownloadAll = DownloadAllRequest(
            targets: targets,
            freeBytes: DeviceStorage.availableBytes(at: model.cache.cacheRootURL)
        )
    }

    private func runDownloadAll(_ targets: [Video]) async {
        downloadingAll = true
        defer { downloadingAll = false }
        // The CacheManager gate bounds transfers, NOT this. `download` calls
        // ensureReady -> POST /prepare and then polls every 2s, all before the
        // gate is acquired. One task per video is what sent 226 simultaneous
        // prepare calls at the server on 2026-07-31.
        await withBoundedTaskGroup(
            limit: model.cache.maxConcurrentDownloads,
            over: targets
        ) { video in
            // Re-checked per item at seed time, not snapshotted: an item can
            // sit queued while its cache state changes underneath it.
            guard model.cache.state(for: video.id, versionId: video.chosenVersionId) == .notCached else { return }
            await download(video, bulk: true)
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
