// ios/PatataTube/Sources/MovieDetailView.swift
import SwiftUI
import PatataTubeKit

/// Pushed detail page for a single movie: poster, summary, play/download.
/// Play and download go through VideoGridView's closures so the Preparing…
/// overlay (attached to the NavigationStack, so it covers pushed views) and
/// error banner behave exactly as they do from the grid.
struct MovieDetailView: View {
    let video: Video
    let onPlay: (Video) -> Void
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: (Video) async -> Bool

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    /// Tracks the button's live transition: idle → loading → done, layered over the cache state.
    @State private var downloadPhase: DownloadPhase = .idle
    /// Live download fraction (0...1), polled from the cache while downloading.
    @State private var progress: Double = 0
    @State private var observedCacheState: CacheState?
    @State private var activeDownloadID: UUID?

    private enum DownloadPhase { case idle, loading, done }

    /// The pushed Video is a value snapshot; prefer the live store row so a
    /// version change made from this page is reflected immediately.
    private var currentVideo: Video {
        store.videos.first { $0.id == video.id } ?? video
    }

    private var chosenVersion: VideoVersion? {
        currentVideo.versions.first { $0.isChosen } ?? currentVideo.versions.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    AuthedImage(path: currentVideo.previewUrl,
                                localFileURL: model.cache.cachedPreviewURL(for: currentVideo.id),
                                fill: false)
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .background(.secondary.opacity(0.2))
                        .cornerRadius(12)
                    Spacer()
                }

                Text(currentVideo.title ?? currentVideo.url)
                    .font(.title2.bold())

                if currentVideo.status != "done" {
                    Text(currentVideo.status).font(.caption).padding(4)
                        .background(.thinMaterial).cornerRadius(4)
                }

                if let summary = currentVideo.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Button {
                        onPlay(currentVideo)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)

                    downloadButton

                    if currentVideo.versions.count > 1 {
                        Picker("Version", selection: Binding(
                            get: { currentVideo.chosenVersionId ?? currentVideo.versions.first?.id ?? 0 },
                            set: { versionId in Task { await store.chooseVersion(id: currentVideo.id, versionId: versionId) } }
                        )) {
                            ForEach(currentVideo.versions) { version in
                                Text(version.label ?? "Version \(version.id)")
                                    .tag(version.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    let audioTracks = chosenVersion?.audioTracks ?? []
                    if audioTracks.count > 1 {
                        Picker("Audio", selection: Binding(
                            get: { currentVideo.audioLang ?? audioTracks.first?.lang ?? "" },
                            set: { lang in
                                guard lang != currentVideo.audioLang else { return }
                                if audioTracks.first(where: { $0.lang == lang })?.available == false {
                                    // Server will re-convert; the cached MP4 is about to go stale.
                                    model.cache.removeCached(id: currentVideo.id,
                                                             versionId: currentVideo.chosenVersionId)
                                }
                                Task { await store.chooseAudio(id: currentVideo.id, lang: lang) }
                            }
                        )) {
                            ForEach(audioTracks, id: \.lang) { track in
                                Text(audioLabel(for: track)).tag(track.lang)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Spacer()
                }
            }
            .padding()
        }
        .navigationTitle(currentVideo.title ?? "Movie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        model.cache.removeAllCached(id: currentVideo.id)
                        // Flip the download button back to the arrow now,
                        // instead of waiting for the 500ms cache poll.
                        activeDownloadID = nil
                        withAnimation {
                            downloadPhase = .idle
                            observedCacheState = .notCached
                            progress = 0
                        }
                    } label: {
                        Label("Delete cached", systemImage: "trash")
                    }
                    .disabled(!model.cache.hasAnyCached(id: currentVideo.id))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: downloadPollKey) {
            await pollCacheState()
        }
        .onChange(of: currentVideo.chosenVersionId) { _, _ in
            activeDownloadID = nil
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
        .onChange(of: currentVideo.audioLang) { _, _ in
            activeDownloadID = nil
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
    }

    private var cacheState: CacheState {
        model.cache.state(for: currentVideo.id, versionId: currentVideo.chosenVersionId)
    }

    /// Local phase wins during the live tap→download→done transition; otherwise trust the cache.
    private var effectiveState: CacheState {
        let observedState = observedCacheState ?? cacheState
        switch downloadPhase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done: return .cached
        case .idle: return observedState
        }
    }

    private var downloadPollKey: String {
        "\(currentVideo.id):\(currentVideo.chosenVersionId ?? -1)"
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    @ViewBuilder private var downloadButton: some View {
        switch effectiveState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
                .transition(.scale.combined(with: .opacity))
        case .downloading:
            Button {
                activeDownloadID = nil
                model.cache.cancel(id: currentVideo.id, versionId: currentVideo.chosenVersionId)
                withAnimation {
                    downloadPhase = .idle
                    observedCacheState = .notCached
                    progress = 0
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: clampedProgress)
                }
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .notCached:
            Button {
                Task {
                    let downloadID = UUID()
                    activeDownloadID = downloadID
                    withAnimation {
                        downloadPhase = .loading
                        observedCacheState = .downloading(0)
                        progress = 0
                    }
                    let ok = await onDownload(currentVideo)
                    guard activeDownloadID == downloadID else { return }
                    activeDownloadID = nil
                    withAnimation {
                        downloadPhase = ok ? .done : .idle
                        observedCacheState = ok ? .cached : .notCached
                        progress = ok ? 1 : 0
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private func pollCacheState() async {
        while !Task.isCancelled {
            let state = cacheState
            updateObservedCacheState(state)

            if case .downloading = state {
                try? await Task.sleep(for: .milliseconds(150))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// "spa" → "Spanish"; the source's title tag disambiguates when present.
    private func audioLabel(for track: AudioTrack) -> String {
        let name = Locale.current.localizedString(forLanguageCode: track.lang) ?? track.lang
        return track.title.isEmpty ? name : "\(name) — \(track.title)"
    }

    private func updateObservedCacheState(_ state: CacheState) {
        observedCacheState = state
        switch state {
        case .downloading(let p):
            progress = p
        case .cached:
            progress = 1
        case .notCached:
            if downloadPhase == .idle {
                progress = 0
            }
        }
    }
}
