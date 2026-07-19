// ios/PatataTube/Sources/MovieCell.swift
import SwiftUI
import PatataTubeKit

/// Portrait 2:3 poster card for the "movies" filter tab. A deliberate fork of
/// VideoCell: the poster is a NavigationLink to MovieDetailView instead of a
/// play button, and the artwork fills a 2:3 frame (Plex movie posters are
/// natively 2:3) rather than being letterboxed into 16:9.
struct MovieCell: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil
    /// Local file URL of the cached MP4 (may not exist on disk yet).
    var localFileURL: URL? = nil
    let classifications: [String]
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void
    let onChooseVersion: (Int) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var showingInfo = false
    /// Tracks the button's live transition: idle → loading → done, layered over `cacheState`.
    @State private var downloadPhase: DownloadPhase = .idle
    /// Live download fraction (0...1), polled from the cache while downloading.
    @State private var progress: Double = 0
    @State private var observedCacheState: CacheState?

    private enum DownloadPhase { case idle, loading, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: video) {
                ZStack {
                    Rectangle().fill(.black)
                    Text(video.title ?? video.url)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    if video.previewUrl != nil || cachedPreviewURL != nil {
                        // scaledToFill previews report their covering size as their
                        // frame, which can exceed the cell; sizing the ZStack from the
                        // black rectangle and clipping here keeps every cell 2:3.
                        Rectangle().fill(.clear)
                            .overlay {
                                AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL)
                            }
                            .clipped()
                    }
                    if video.status != "done" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                }
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                downloadButton
                Spacer()
                if video.versions.count > 1 {
                    Picker("Version", selection: Binding(
                        get: { video.chosenVersionId ?? video.versions.first?.id ?? 0 },
                        set: { onChooseVersion($0) }
                    )) {
                        ForEach(video.versions) { version in
                            Text(version.label ?? "Version \(version.id)")
                                .tag(version.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Menu {
                    Button("Info", systemImage: "info.circle") { showingInfo = true }
                    Button("Move up") { onMoveUp() }
                    Button("Move down") { onMoveDown() }
                    Divider()
                    ForEach(classifications, id: \.self) { c in
                        Button(c) { onClassify(c) }
                    }
                    Divider()
                    Button("Delete video", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 30))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, cacheState: effectiveState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
        .task(id: downloadPollKey) {
            await pollCacheState()
        }
        .onChange(of: cacheState) { _, newState in
            updateObservedCacheState(newState)
        }
        .onChange(of: video.chosenVersionId) { _, _ in
            downloadPhase = .idle
            observedCacheState = nil
            progress = 0
        }
    }

    /// Local phase wins during the live tap→download→done transition; otherwise trust the parent.
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
        "\(video.id):\(video.chosenVersionId ?? -1)"
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
                onCancel()
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
                    withAnimation {
                        downloadPhase = .loading
                        observedCacheState = .downloading(0)
                        progress = 0
                    }
                    let ok = await onDownload()
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
            let state = currentCacheState()
            updateObservedCacheState(state)

            if case .downloading = state {
                try? await Task.sleep(for: .milliseconds(150))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
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
