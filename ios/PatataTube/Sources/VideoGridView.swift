// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    @State private var classifications: [String] = ["children", "adults", "education", "tv", "movies"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var playing: Video?
    @State private var preparing = false

    // Grid cell size, adjustable via +/- buttons. Persisted across launches.
    @AppStorage("gridCellSize") private var cellSize: Double = 220
    private let minCellSize: Double = 120
    private let maxCellSize: Double = 420
    private let cellSizeStep: Double = 50

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                filterTabs
                if store.filter == "tv" {
                    ShowsView(videos: store.videos,
                              onPlay: { play($0) },
                              onDownload: { download($0) })
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.videos) { video in
                            VideoCell(
                                video: video,
                                cacheState: model.cache.state(for: video.id),
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id),
                                classifications: classifications,
                                onPlay: { play(video) },
                                onDownload: { download(video) },
                                onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                                onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                                onClassify: { c in Task { await store.classify(id: video.id, to: c) } },
                                onDelete: { Task { await store.delete(id: video.id) } }
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("PatataTube")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        cellSize = max(cellSize - cellSizeStep, minCellSize)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(cellSize <= minCellSize)
                    Button {
                        cellSize = min(cellSize + cellSizeStep, maxCellSize)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(cellSize >= maxCellSize)
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
                VideoPlayerView(video: video)
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
        // Already downloaded to device: play the local file directly, no network.
        // ensureReady() would hit /prepare and fail offline (-1009) even though
        // the cached MP4 is ready to play. VideoPlayerView plays from cache too.
        if model.cache.state(for: video.id) == .cached {
            playing = video
            return
        }
        guard video.isLibrary, video.status != "done" else {
            playing = video
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                playing = try await store.ensureReady(id: video.id)
            } catch {
                store.errorText = String(describing: error)
            }
        }
    }

    private func download(_ video: Video) {
        Task {
            var target = video
            if video.isLibrary, video.status != "done" {
                preparing = true
                defer { preparing = false }
                do { target = try await store.ensureReady(id: video.id) }
                catch { store.errorText = String(describing: error); return }
            }
            guard let url = model.streamURL(for: target) else { return }
            let preview: URL?
            if let p = target.previewUrl {
                preview = p.hasPrefix("http") ? URL(string: p)
                    : model.credentials.baseURL?.appendingPathComponent(
                        p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            } else { preview = nil }
            try? await model.cache.download(id: target.id, from: url, preview: preview,
                                            bearerToken: model.credentials.token)
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
