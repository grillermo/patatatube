// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    @State private var classifications: [String] = ["children", "adults", "education", "entertainment"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var playing: Video?

    // Grid cell size, adjustable via pinch/spread. Persisted across launches.
    @AppStorage("gridCellSize") private var cellSize: Double = 220
    @State private var gestureBaseSize: Double = 220
    private let minCellSize: Double = 120
    private let maxCellSize: Double = 420

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                filterTabs
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.videos) { video in
                        VideoCell(
                            video: video,
                            cacheState: model.cache.state(for: video.id),
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id),
                            classifications: classifications,
                            onPlay: { playing = video },
                            onDownload: { await download(video) },
                            onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                            onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                            onClassify: { c in Task { await store.classify(id: video.id, to: c) } },
                            onDelete: { Task { await store.delete(id: video.id) } }
                        )
                    }
                }
                .padding()
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let proposed = gestureBaseSize * value.magnification
                        cellSize = min(max(proposed, minCellSize), maxCellSize)
                    }
                    .onEnded { _ in gestureBaseSize = cellSize }
            )
            .onAppear { gestureBaseSize = cellSize }
            .navigationTitle("PatataTube")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
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

    private func download(_ video: Video) async {
        guard let url = model.streamURL(for: video) else { return }
        let preview = video.previewUrl.flatMap(URL.init(string:))
        try? await model.cache.download(id: video.id, from: url, preview: preview)
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
