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

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                filterTabs
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.videos) { video in
                        VideoCell(
                            video: video,
                            cacheState: model.cache.state(for: video.id),
                            classifications: classifications,
                            onPlay: { playing = video },
                            onDownload: { download(video) },
                            onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                            onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                            onClassify: { c in Task { await store.classify(id: video.id, to: c) } }
                        )
                    }
                }
                .padding()
            }
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
        await store.load()
    }

    private func download(_ video: Video) {
        guard let url = model.streamURL(for: video) else { return }
        Task { try? await model.cache.download(id: video.id, from: url) }
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
