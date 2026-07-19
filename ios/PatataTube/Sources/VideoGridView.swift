// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var classifications: [String] = ["children", "adults", "education", "tv", "movies"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var playing: Video?
    /// Snapshot of the visible list taken when playback starts; the lock-screen
    /// next/previous queue. Grid refreshes don't mutate an active queue.
    @State private var playQueue: [Video] = []
    @State private var preparing = false
    @State private var downloadingAll = false

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
                    ShowsView(videos: filteredVideos,
                              onPlay: { play($0) },
                              onDownload: { v in Task { await download(v) } })
                } else if store.filter == "movies" {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredVideos) { video in
                            MovieCell(
                                video: video,
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id)
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
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id),
                                localFileURL: cache.localURL(for: videoId, versionId: versionId),
                                classifications: classifications,
                                onPlay: { play(video) },
                                onDownload: { await download(video) },
                                onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                                onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                                onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task { await downloadAll() }
                            } label: { Label("Download all", systemImage: "arrow.down.circle") }
                            .disabled(downloadingAll)
                            Button {
                                cellSize = max(cellSize - cellSizeStep, minCellSize)
                            } label: { Label("Smaller cells", systemImage: "minus.magnifyingglass") }
                            .disabled(cellSize <= minCellSize)
                            Button {
                                cellSize = min(cellSize + cellSizeStep, maxCellSize)
                            } label: { Label("Bigger cells", systemImage: "plus.magnifyingglass") }
                            .disabled(cellSize >= maxCellSize)
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task { await downloadAll() }
                        } label: {
                            if downloadingAll { ProgressView() }
                            else { Image(systemName: "arrow.down.circle") }
                        }
                        .disabled(downloadingAll)
                        Button {
                            cellSize = max(cellSize - cellSizeStep, minCellSize)
                        } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(cellSize <= minCellSize)
                        Button {
                            cellSize = min(cellSize + cellSizeStep, maxCellSize)
                        } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(cellSize >= maxCellSize)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUpload = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await store.load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showUpload) { UploadView() }
            .fullScreenCover(item: $playing) { video in
                VideoPlayerView(
                    videos: playQueue,
                    startIndex: playQueue.firstIndex(where: { $0.id == video.id }) ?? 0
                )
            }
            .task { await initialLoad() }
            .overlay { if let error = store.errorText { errorBanner(error) } }
        }
        // Attached to the NavigationStack itself (not the root ScrollView) so it renders
        // above any pushed destination (e.g. EpisodesView), where taps must also be
        // blocked while a TV episode is being prepared server-side.
        .overlay {
            if preparing {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing…").foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.thinMaterial)
                    .cornerRadius(12)
                }
            }
        }
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
    }

    private func play(_ video: Video) {
        let queueSnapshot = filteredVideos

        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            startPlayback(video, queueSnapshot: queueSnapshot)
            return
        }
        guard video.isLibrary, video.status != "done" else {
            startPlayback(video, queueSnapshot: queueSnapshot)
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                startPlayback(
                    try await store.ensureReady(id: video.id),
                    queueSnapshot: queueSnapshot
                )
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    /// Starts playback from the tap-time queue snapshot. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    private func startPlayback(_ video: Video, queueSnapshot: [Video]) {
        var queue = queueSnapshot
        if let index = queue.firstIndex(where: { $0.id == video.id }) {
            queue[index] = video
        } else {
            queue = [video]
        }
        playQueue = queue
        playing = video
    }

    /// Downloads a video for offline playback. Returns true only when the MP4
    /// actually landed on disk, so the caller's checkmark reflects reality.
    @discardableResult
    private func download(_ video: Video) async -> Bool {
        var target = video
        if video.isLibrary, video.status != "done" {
            preparing = true
            defer { preparing = false }
            do { target = try await store.ensureReady(id: video.id) }
            catch { store.errorText = String(describing: error); return false }
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
                                           bearerToken: model.credentials.token)
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
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Downloads every not-yet-cached video currently in view (respects the active filter).
    private func downloadAll() async {
        downloadingAll = true
        defer { downloadingAll = false }
        for video in store.videos where model.cache.state(for: video.id, versionId: video.chosenVersionId) == .notCached {
            await download(video)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.caption).padding()
                .background(.red.opacity(0.85)).foregroundStyle(.white).cornerRadius(8)
                .padding()
        }
    }
}
