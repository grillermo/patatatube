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

/// The six restoration save-triggers, pulled out of `VideoGridView.body` as a
/// separate `ViewModifier`: inlined as `.onChange` calls directly in the
/// modifier chain, they pushed the type checker past its time budget.
private struct RestorationTracking: ViewModifier {
    let path: [Route]
    let tab: MediaTab
    let selectedTab: MediaTab
    let activation: MediaTab?
    let feed: Feed?
    let activeSearch: String
    let playing: PlaybackQueue?
    let scenePhase: ScenePhase
    let model: AppModel
    let gridTracker: VisibleItemsTracker
    @Binding var gridAnchorDebounceTask: Task<Void, Never>?
    @Binding var searchDebounceTask: Task<Void, Never>?
    let currentGridOrder: [String]
    let activateGroup: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeSearch) { _, newValue in
                guard selectedTab == tab else { return }
                model.restorationStore.mutate { $0.search = newValue }
            }
            .onChange(of: path) { oldValue, newValue in
                DevLog.event(.nav, "grid path changed", [
                    "from": RestorationTracking.describe(oldValue),
                    "to": RestorationTracking.describe(newValue),
                ])
                guard selectedTab == tab else { return }
                model.restorationStore.mutate {
                    $0.tab = tab
                    $0.path = newValue
                }
            }
            .onChange(of: feed) { _, newValue in
                guard selectedTab == tab else { return }
                model.restorationStore.mutate { $0.feed = newValue }
            }
            .onChange(of: activation) { _, selectedTab in
                guard selectedTab == tab else { return }
                let selectedFeed: Feed?
                if tab == .videos, case .group(let id)? = path.first {
                    selectedFeed = .group(id: id)
                } else {
                    selectedFeed = tab.feed
                }
                model.restorationStore.mutate {
                    $0.tab = tab
                    $0.feed = selectedFeed
                    $0.path = path
                    $0.search = selectedFeed == nil ? "" : activeSearch
                }
                if tab == .videos, case .group(let id)? = selectedFeed { activateGroup(id) }
            }
            .onChange(of: selectedTab) { _, newValue in
                guard newValue != tab else { return }
                searchDebounceTask?.cancel()
                gridAnchorDebounceTask?.cancel()
            }
            .onChange(of: currentGridOrder) { _, newValue in
                gridTracker.setOrder(newValue)
            }
            .onChange(of: playing) { oldValue, newValue in
                guard selectedTab == tab else { return }
                DevLog.event(.nav, "grid playing changed", [
                    "from": oldValue.map { "\($0.videos[$0.startIndex].id)" } ?? "nil",
                    "to": newValue.map { "\($0.videos[$0.startIndex].id)" } ?? "nil",
                ])
                model.restorationStore.mutate { state in
                    state.player = newValue.map { queue in
                        let video = queue.videos[queue.startIndex]
                        return PlayerState(videoID: video.id, versionID: video.chosenVersionId, sleepMode: queue.sleepMode)
                    }
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                guard selectedTab == tab else { return }
                guard newValue != .active else { return }
                // Flush the debounced anchor write immediately — the app can
                // be suspended before the 0.5s debounce fires.
                gridAnchorDebounceTask?.cancel()
                if let topmost = gridTracker.topmost, let feed {
                    let key = RestorationState.gridKey(feed: feed)
                    model.restorationStore.mutate { $0.scrollAnchors[key] = topmost }
                }
            }
    }

    static func describe(_ path: [Route]) -> String {
        path.map { route in
            switch route {
            case .group(let id): return "group(\(id))"
            case .show(let title): return "show(\(title))"
            case .movie(let id): return "movie(\(id))"
            case .downloads: return "downloads"
            }
        }.joined(separator: ">")
    }
}

private extension View {
    func restorationTracking(
        path: [Route], tab: MediaTab, selectedTab: MediaTab,
        activation: MediaTab?,
        feed: Feed?, activeSearch: String,
        playing: PlaybackQueue?, scenePhase: ScenePhase,
        model: AppModel, gridTracker: VisibleItemsTracker,
        gridAnchorDebounceTask: Binding<Task<Void, Never>?>,
        searchDebounceTask: Binding<Task<Void, Never>?>,
        currentGridOrder: [String], activateGroup: @escaping (Int) -> Void
    ) -> some View {
        modifier(RestorationTracking(
            path: path, tab: tab, selectedTab: selectedTab,
            activation: activation,
            feed: feed, activeSearch: activeSearch,
            playing: playing, scenePhase: scenePhase,
            model: model, gridTracker: gridTracker,
            gridAnchorDebounceTask: gridAnchorDebounceTask,
            searchDebounceTask: searchDebounceTask,
            currentGridOrder: currentGridOrder, activateGroup: activateGroup
        ))
    }
}

struct VideoGridView: View {
    /// Which tab this instance is the content of. Fixed for the lifetime of the
    /// view — `RootTabView` builds one instance per tab.
    let tab: MediaTab
    /// Set only for a user-initiated tab selection. Launch restoration changes
    /// `RootTabView.selection` directly so an empty stack cannot overwrite it.
    let activation: MediaTab?
    /// Current tab-bar selection, used to reject delayed writes from retained
    /// inactive stacks.
    let selectedTab: MediaTab

    init(tab: MediaTab, groups: GroupStore, selectedTab: MediaTab? = nil, activation: MediaTab? = nil) {
        self.tab = tab
        _groups = ObservedObject(wrappedValue: groups)
        self.selectedTab = selectedTab ?? tab
        self.activation = activation
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var groups: GroupStore

    @State private var loadedGroup: Int?
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var showWebBridge = false
    /// Explicit navigation path. Required for restoration — an implicit stack
    /// cannot be replayed — and the reason `.downloads` is a route rather than
    /// an `isPresented` destination: SwiftUI desyncs a stack that mixes the two.
    @State private var path: [Route] = []
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

    /// Tracks the topmost on-screen item of the root grid (whichever
    /// feed is showing), for scroll restoration.
    @State private var gridTracker = VisibleItemsTracker()
    @State private var gridAnchorDebounceTask: Task<Void, Never>?
    @State private var restoredGroupAnchor: String?

    // Search: text updates immediately for the field, but filtering only
    // applies 0.5s after the user stops typing (debounce), to avoid
    // re-filtering the grid on every keystroke.
    @State private var searchText = ""
    @State private var activeSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    // Grid cell size, adjustable via +/- buttons. Persisted across launches and
    // scoped per feed, so sizing one group leaves the others alone.
    /// Set only while a pinch is tracking; overrides the persisted size for
    /// rendering so the grid reflows live. `nil` the rest of the time.
    @State private var pinchLiveSize: Double?
    /// The size a pinch gesture started from — captured on first touch so
    /// `pinchLiveSize` scales from the persisted value, not from whatever
    /// `pinchLiveSize` last was.
    @State private var pinchStartSize: Double?

    private var cellSize: Double {
        pinchLiveSize ?? model.cellSize(for: store.feed)
    }
    /// List or grid, derived from the live-or-persisted size.
    private var displayMode: GridDisplayMode { GridDisplayMode.forCellSize(cellSize) }

    /// Pinch-to-resize: live-tracks scale against the size the gesture
    /// started from, then snaps to the nearest canonical stop and persists
    /// it exactly like the ellipsis menu's size buttons do.
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                if pinchStartSize == nil { pinchStartSize = base }
                pinchLiveSize = GridDisplayMode.clampedCellSize(base * scale)
            }
            .onEnded { scale in
                let base = pinchStartSize ?? model.cellSize(for: store.feed)
                let raw = GridDisplayMode.clampedCellSize(base * scale)
                model.setCellSize(GridDisplayMode.nearestCanonicalSize(to: raw), for: store.feed)
                pinchStartSize = nil
                pinchLiveSize = nil
            }
    }
    /// Rows carry their own divider and sit flush; cards keep the 16pt gutter.
    private var gridSpacing: CGFloat {
        if case .list = displayMode { return 0 }
        return 16
    }

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
        switch displayMode {
        case .list:
            return [GridItem(.flexible(), spacing: 0)]
        case .grid(let size):
            return [GridItem(.adaptive(minimum: size), spacing: 16)]
        }
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
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                tabRoot
                .task { await initialLoad(scrollProxy: proxy) }
                .task { await refreshGroups() }
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: searchText) { _, newValue in
                searchDebounceTask?.cancel()
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    activeSearch = newValue
                }
            }
            .restorationTracking(
                path: path, tab: tab, selectedTab: selectedTab,
                activation: activation,
                feed: store.feed, activeSearch: activeSearch,
                playing: playing, scenePhase: scenePhase,
                model: model, gridTracker: gridTracker,
                gridAnchorDebounceTask: $gridAnchorDebounceTask,
                searchDebounceTask: $searchDebounceTask,
                currentGridOrder: currentGridOrder,
                activateGroup: { id in Task { await loadGroup(id) } }
            )
            .toolbar { optionsToolbar }
            .onChange(of: path) { _, newPath in
                guard tab == .videos else { return }
                guard case .group(let id)? = newPath.first else {
                    searchDebounceTask?.cancel()
                    searchText = ""
                    activeSearch = ""
                    return
                }
                Task { await loadGroup(id) }
            }
            .onChange(of: model.webBridgeRequests) { _, _ in showWebBridge = true }
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
                    path.append(.downloads)
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
                          sleepMode: request.sleepMode, startSecs: request.secs,
                          caller: "resume-alert")
                }
                Button("Play from start") {
                    pendingResume = nil
                    begin(request.video, queueSnapshot: request.queueSnapshot,
                          sleepMode: request.sleepMode, startSecs: 0,
                          caller: "resume-alert-start")
                }
                Button("Cancel", role: .cancel) { pendingResume = nil }
            } message: { request in
                Text("You stopped at \(ResumeDecision.timestamp(request.secs)).")
            }
            .fullScreenCover(item: $playing) { request in
                playerCover(request)
            }
            .overlay { if let error = store.errorText { errorBanner(error) } }
        }
        .environment(preparationTracker)
    }

    @ViewBuilder
    private var tabRoot: some View {
        if tab == .videos {
            rootScrollView.refreshable { await refreshGroups() }
        } else {
            rootScrollView
                .searchable(text: $searchText, prompt: "Search videos")
                .refreshable { await store.refreshLibrary() }
        }
    }

    private func refreshGroups() async {
        if let remote = try? await model.api.groups() {
            groups.apply(remote)
        }
    }

    private var rootScrollView: some View {
        ScrollView {
            if store.isLoading && filteredVideos.isEmpty && tab != .videos {
                SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                             showsTextBars: tab == .tv,
                             isList: displayMode == .list)
            } else {
                switch tab {
                case .videos:
                    GroupsView(groups: groups)
                case .tv:
                    ShowsView(
                        videos: filteredVideos,
                        onPlay: { video, queue in
                            play(video, queueSnapshot: queue, caller: "shows")
                        },
                        onDownload: { await download($0) },
                        onItemAppear: { gridItemAppeared($0) },
                        onItemDisappear: { gridItemDisappeared($0) }
                    )
                case .movies:
                    moviesGrid
                }
            }
        }
        .gesture(pinchGesture)
    }

    /// The cover's content, as a plain function rather than inline in the
    /// `fullScreenCover` builder, so each evaluation can be logged: a rebuild
    /// here without a `begin playback` above it means SwiftUI re-created the
    /// presentation's content rather than the app re-presenting it.
    private func playerCover(_ request: PlaybackQueue) -> some View {
        DevLog.event(.nav, "player cover built", [
            "video_id": "\(request.id)",
            "start_secs": "\(request.startSecs)",
            "start_paused": "\(request.startPaused)",
        ])
        return VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                               sleepMode: request.sleepMode,
                               randomize: model.randomize(for: playbackScope),
                               startSecs: request.startSecs,
                               startPaused: request.startPaused,
                               autoplayScope: playbackScope)
    }

    /// Split out of `body` alongside `defaultGrid` — inlined, the combined
    /// expression pushed the type checker past its time budget.
    private var moviesGrid: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(filteredVideos) { video in
                Group {
                    if case .list = displayMode {
                        MovieRow(
                            video: video,
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                        )
                    } else {
                        MovieCell(
                            video: video,
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                        )
                    }
                }
                .id(String(video.id))
                .onAppear { gridItemAppeared(String(video.id)) }
                .onDisappear { gridItemDisappeared(String(video.id)) }
            }
        }
        .padding()
    }

    private var defaultGrid: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(filteredVideos) { video in
                let cache = model.cache
                let videoId = video.id
                let versionId = video.chosenVersionId
                Group {
                    if case .list = displayMode {
                        VideoRow(
                            video: video,
                            cacheState: cache.state(for: videoId, versionId: versionId),
                            currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl),
                            onPreviewLoaded: { data in
                                guard let path = video.previewUrl,
                                      cache.cachedPreviewURL(for: videoId, path: path) == nil else { return }
                                cache.storePreview(data, for: videoId, path: path)
                            },
                            localFileURL: cache.localURL(for: videoId, versionId: versionId),
                            groups: groups.groups,
                            onPlay: { play(video, caller: "grid-row") },
                            onPlaySleep: { play(video, sleepMode: true, caller: "grid-row-sleep") },
                            onDownload: { await download(video) },
                            onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                            onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) },
                            onSetGroup: { groupID in Task { await store.setGroup(id: video.id, groupID: groupID) } },
                            onPromote: { kind in Task { await store.promote(id: video.id, kind: kind) } },
                            onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                            onDelete: { Task { await store.delete(id: video.id) } }
                        )
                    } else {
                        VideoCell(
                            video: video,
                            cacheState: cache.state(for: videoId, versionId: versionId),
                            currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl),
                            onPreviewLoaded: { data in
                                guard let path = video.previewUrl,
                                      cache.cachedPreviewURL(for: videoId, path: path) == nil else { return }
                                cache.storePreview(data, for: videoId, path: path)
                            },
                            localFileURL: cache.localURL(for: videoId, versionId: versionId),
                            groups: groups.groups,
                            onPlay: { play(video, caller: "grid-cell") },
                            onPlaySleep: { play(video, sleepMode: true, caller: "grid-cell-sleep") },
                            onDownload: { await download(video) },
                            onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                            onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) },
                            onSetGroup: { groupID in Task { await store.setGroup(id: video.id, groupID: groupID) } },
                            onPromote: { kind in Task { await store.promote(id: video.id, kind: kind) } },
                            onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                            onDelete: { Task { await store.delete(id: video.id) } }
                        )
                    }
                }
                .id(String(videoId))
                .onAppear { gridItemAppeared(String(videoId)) }
                .onDisappear { gridItemDisappeared(String(videoId)) }
            }
        }
        .padding()
    }

    /// The same trailing bar for the tab root and for a pushed group, so the
    /// ellipsis sits on the row that carries the Back button instead of
    /// vanishing the moment a group opens.
    @ToolbarContentBuilder
    private var optionsToolbar: some ToolbarContent {
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

    private var optionsMenu: some View {
        Menu {
            Button {
                showUpload = true
            } label: { Label("New video", systemImage: "plus") }

            Toggle(isOn: model.autoplayBinding(for: store.feed)) {
                Label("Autoplay", systemImage: "play.circle")
            }

            Toggle(isOn: model.randomizeBinding(for: store.feed)) {
                Label("Randomize", systemImage: "shuffle")
            }

            Divider()

            Button {
                presentDownloadAll()
            } label: { Label("Download all", systemImage: "arrow.down.circle") }
            .disabled(downloadingAll || !showsVideoGrid)

            Button {
                path.append(.downloads)
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }

            let smallerStep = GridDisplayMode.smaller(from: model.cellSize(for: store.feed))
            Button {
                if let smallerStep { model.setCellSize(smallerStep.target, for: store.feed) }
            } label: {
                Label(smallerStep?.title ?? "Smaller cells",
                      systemImage: smallerStep?.systemImage ?? "minus.magnifyingglass")
            }
            .disabled(smallerStep == nil)

            let biggerStep = GridDisplayMode.bigger(from: model.cellSize(for: store.feed))
            Button {
                if let biggerStep { model.setCellSize(biggerStep.target, for: store.feed) }
            } label: {
                Label(biggerStep?.title ?? "Bigger cells",
                      systemImage: biggerStep?.systemImage ?? "plus.magnifyingglass")
            }
            .disabled(biggerStep == nil)

            Divider()

            Button {
                showSettings = true
            } label: { Label("Settings", systemImage: "gear") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// Resolved late, against the list actually on screen: a route holds only
    /// an id, so a renamed or deleted show resolves to nothing instead of a
    /// phantom screen. Split out of `body` — inlined as one giant switch it
    /// pushed the type checker past its time budget.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .group:
            ScrollViewReader { proxy in
                ScrollView {
                    if store.isLoading && filteredVideos.isEmpty {
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0,
                                     isList: displayMode == .list)
                    } else {
                        defaultGrid
                    }
                }
                .gesture(pinchGesture)
                .task(id: restoredGroupAnchor) {
                    guard let anchor = restoredGroupAnchor else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                    restoredGroupAnchor = nil
                }
            }
            .searchable(text: $searchText, prompt: "Search videos")
            .refreshable { await store.refreshLibrary() }
            .toolbar { optionsToolbar }
        case .show(let title):
            if let show = ShowGroup.group(filteredVideos).first(where: { $0.id == title }) {
                EpisodesView(show: show,
                             onPlay: { video, queue in play(video, queueSnapshot: queue, caller: "episodes") },
                             onDownload: { await download($0) },
                             showDownloads: { path.append(.downloads) })
            } else {
                EmptyView().onAppear {
                    DevLog.event(.nav, "show route unresolved", ["title": title])
                }
            }
        case .movie(let id):
            if let video = store.videos.first(where: { $0.id == id }) {
                MovieDetailView(video: video,
                                onPlay: { play($0, caller: "movie-detail") },
                                onDownload: { await download($0) })
            }
        case .downloads:
            DownloadsView(
                active: { model.cache.activeDownloads() },
                recent: { model.cache.recentDownloads() },
                video: { id, versionID in
                    Self.downloadVideo(id: id, versionID: versionID, videos: store.videos)
                },
                onCancel: { activity in
                    model.cache.cancel(id: activity.videoID, versionId: activity.versionID)
                },
                onPlay: { video in play(video, caller: "downloads") }
            )
        }
    }

    /// Order is load-bearing: the restored path and player resolve against
    /// `store.videos`, which only exists after `bootLoad()` returns, and the
    /// search text has to be applied before `filteredVideos` (which both
    /// depend on) is read.
    ///
    /// Claims `model.restorationGate` first. SwiftUI restarts a `.task` every
    /// time its view re-enters the hierarchy, and dismissing the player's
    /// `fullScreenCover` does exactly that — ungated, each dismissal re-ran
    /// this function against a snapshot read before its `await`s and
    /// re-presented the player it had just dismissed, or cleared `path` and
    /// popped `EpisodesView` under the user's tap
    /// (`docs/restoration-buggy.md`).
    private func initialLoad(scrollProxy: ScrollViewProxy) async {
        let restoredTab = model.restorationStore.load().tab ?? .videos
        guard tab == restoredTab else {
            DevLog.event(.nav, "initial load skipped", ["reason": "other tab", "tab": tab.rawValue])
            return
        }
        guard model.restorationGate.claim() else {
            DevLog.event(.nav, "initial load skipped", ["reason": "already restored"])
            return
        }

        let restored = model.restorationStore.load()
        // Videos tab restored at its root has no feed to fetch.
        let restoredGroup: Int? = {
            if case .group(let id)? = restored.path.first { return id }
            return nil
        }()
        if tab == .videos {
            if let restoredGroup {
                await loadGroup(restoredGroup)
            }
        } else {
            if let feed = tab.feed, store.feed != feed {
                await store.switchFeed(to: feed)
            } else {
                await store.bootLoad()
            }
        }

        searchText = restored.search
        activeSearch = restored.search

        // An explicit launch intent (home-screen quick action) must not be
        // overridden by whatever was playing last session.
        let resolved = RestorationResolver.resolve(
            state: restored,
            videos: store.videos,
            hasPendingQuickAction: QuickActionRouter.shared.pending != nil
        )
        let applyPath = RestorationApplyDecision.shouldApplyPath(
            restoredIsEmpty: resolved.path.isEmpty, liveIsEmpty: path.isEmpty
        )
        let applyPlayer = RestorationApplyDecision.shouldApplyPlayer(
            hasRestoredPlayer: resolved.player != nil, hasLivePlayer: playing != nil
        )
        DevLog.event(.nav, "initial load applying", [
            "path": RestorationTracking.describe(resolved.path),
            "player": resolved.player.map { "\($0.video.id)" } ?? "nil",
            "apply_path": "\(applyPath)",
            "apply_player": "\(applyPlayer)",
        ])
        if applyPath { path = resolved.path }
        if applyPlayer, let player = resolved.player {
            let startSecs = model.resumeStore.resolved(server: player.video.resumeSecs, for: player.video.id)
            playing = PlaybackQueue(
                video: player.video,
                queueSnapshot: player.queue,
                sleepMode: player.sleepMode,
                startSecs: startSecs,
                startPaused: true
            )
        }

        gridTracker.setOrder(currentGridOrder)
        if let anchor = restored.scrollAnchors[RestorationState.gridKey(feed: store.feed)] {
            if tab == .videos, restoredGroup != nil {
                restoredGroupAnchor = anchor
            } else {
                // LazyVGrid/List need a render pass after the data lands before
                // an off-screen id resolves to a position.
                try? await Task.sleep(nanoseconds: 100_000_000)
                scrollProxy.scrollTo(anchor, anchor: .top)
            }
        }

        // Footprint after the list lands: correlates library size + in-flight
        // downloads with the OOM watchdog kills (PATATATUBE-6, -2).
        MemoryProbe.snapshot("grid-loaded", extra: [
            "video_count": store.videos.count,
            "active_downloads": model.cache.activeDownloads().count,
        ])
    }

    private func loadGroup(_ id: Int) async {
        let feed = Feed.group(id: id)
        if loadedGroup != id || store.feed != feed {
            loadedGroup = id
            await store.switchFeed(to: feed)
        }
    }

    private var currentGridOrder: [String] {
        if store.feed == .plex(.tv) {
            return ShowGroup.group(filteredVideos).map { $0.id }
        }
        return filteredVideos.map { String($0.id) }
    }

    /// The group whose grid is on screen, or nil on the tv/movies tabs.
    /// Bucket the playback settings (autoplay, randomize) are read from: the
    /// open show when one is pushed, otherwise the tab/group feed. Read at
    /// presentation time — the path cannot change under a full-screen player.
    private var playbackScope: String? {
        for route in path.reversed() {
            if case .show(let title) = route { return AppModel.showScope(title) }
        }
        return store.feed.storageKey
    }

    private var currentGroupID: Int? {
        guard tab == .videos, case .group(let id)? = path.first else { return nil }
        return id
    }

    private var showsVideoGrid: Bool {
        guard tab == .videos else { return true }
        if case .group? = path.first { return true }
        return false
    }

    private func gridItemAppeared(_ id: String) {
        gridTracker.appeared(id)
        scheduleGridAnchorSave()
    }

    private func gridItemDisappeared(_ id: String) {
        gridTracker.disappeared(id)
        scheduleGridAnchorSave()
    }

    private func scheduleGridAnchorSave() {
        // Retained inactive stacks keep delivering onDisappear after a tab
        // switch, and `key` comes from the *shared* store feed — which has
        // already flipped to the incoming tab. Ungated, the outgoing tab's
        // topmost id lands under the incoming tab's key and clobbers its
        // anchor. Same scoping every other restoration write uses.
        guard selectedTab == tab else { return }
        let key = RestorationState.gridKey(feed: store.feed)
        gridAnchorDebounceTask?.cancel()
        gridAnchorDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let topmost = gridTracker.topmost else { return }
            model.restorationStore.mutate { $0.scrollAnchors[key] = topmost }
        }
    }

    private func play(_ video: Video, sleepMode: Bool = false, caller: String = "?") {
        let queueSnapshot = filteredVideos
        play(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, caller: caller)
    }

    private func play(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false, caller: String = "?") {
        DevLog.event(.nav, "play requested", ["video_id": "\(video.id)", "caller": caller])
        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, caller: caller)
            return
        }
        guard video.isLibrary, video.status != "done" else {
            startPlayback(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, caller: caller)
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
                    sleepMode: sleepMode,
                    caller: caller
                )
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    /// Starts playback from the tap-time queue snapshot. `video` may be the
    /// ensureReady-updated copy, so it replaces its stale row in the snapshot.
    /// tv/movies rows with real progress stop here and ask first.
    private func startPlayback(_ video: Video, queueSnapshot: [Video], sleepMode: Bool = false, caller: String = "?") {
        let secs = model.resumeStore.resolved(server: video.resumeSecs, for: video.id)
        switch ResumeDecision.decide(resumeSecs: secs, plexKind: video.plexKind) {
        case .ask(let secs):
            pendingResume = PendingResume(
                id: video.id,
                video: video,
                queueSnapshot: queueSnapshot,
                sleepMode: sleepMode,
                secs: secs
            )
        case .playFromStart:
            begin(video, queueSnapshot: queueSnapshot, sleepMode: sleepMode, startSecs: 0, caller: caller)
        }
    }

    private func begin(
        _ video: Video,
        queueSnapshot: [Video],
        sleepMode: Bool,
        startSecs: Double,
        caller: String = "?"
    ) {
        DevLog.event(.nav, "begin playback", [
            "video_id": "\(video.id)", "caller": caller, "start_secs": "\(startSecs)",
            "had_playing": playing.map { "\($0.id)" } ?? "nil",
        ])
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
        guard showsVideoGrid else { return }
        // Scoped to the open group, not just to whatever the shared store last
        // loaded: the menu now also exists on the pushed group screen, and a
        // switchFeed still in flight would otherwise let the previous group's
        // rows into the batch.
        let groupID = currentGroupID
        let targets = filteredVideos.filter {
            if let groupID, $0.groupID != groupID { return false }
            return model.cache.state(for: $0.id, versionId: $0.chosenVersionId) == .notCached
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
