// ios/PatataTube/Sources/VideoCell.swift
import SwiftUI
import PatataTubeKit

struct VideoCell: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil
    /// Local file URL of the cached MP4 (may not exist on disk yet).
    var localFileURL: URL? = nil
    let classifications: [String]
    let onPlay: () -> Void
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

    /// tv/movies previews are tall Plex posters; letterbox them instead of cropping.
    private var isPoster: Bool {
        video.classification == "tv" || video.classification == "movies"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
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
                        // black rectangle and clipping here keeps every cell 16:9.
                        // tv/movies use tall Plex posters — letterbox (fit) them so
                        // they aren't center-cropped; everything else fills the frame.
                        Rectangle().fill(.clear)
                            .overlay {
                                AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                            fill: !isPoster)
                            }
                            .clipped()
                    }
                    if video.status != "done" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                }
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                DownloadButton(
                    identity: DownloadButtonIdentity(
                        videoID: video.id,
                        versionID: video.chosenVersionId,
                        audioLanguage: video.audioLang
                    ),
                    currentCacheState: currentCacheState,
                    onDownload: onDownload,
                    onCancel: onCancel
                )
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
            VideoInfoView(video: video, cacheState: cacheState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
    }

}

/// A modal listing every locally-known field about a video, plus its on-disk
/// cache state (path + size). Read-only inspector reached from the "Info" menu.
struct VideoInfoView: View {
    let video: Video
    let cacheState: CacheState
    let cachedPreviewURL: URL?
    let localFileURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Video") {
                    row("ID", "\(video.id)")
                    row("Title", video.title)
                    row("URL", video.url)
                    row("Platform", video.platform)
                    row("Source", video.source)
                    row("Source key", video.sourceKey)
                    row("Source filename", video.sourceFilename)
                    row("Classification", video.classification)
                    row("Position", video.position.map { "\($0)" })
                    row("Status", video.status)
                    row("Error", video.errorMsg)
                }

                Section("Show") {
                    row("Show title", video.showTitle)
                    row("Season", video.season.map { "\($0)" })
                    row("Episode", video.episode.map { "\($0)" })
                    row("Summary", video.summary)
                }

                Section("Playback") {
                    row("Stream path", video.streamPath)
                    row("HLS path", video.hlsPath)
                    row("Preview URL", video.previewUrl)
                    row("Show preview URL", video.showPreviewUrl)
                    row("Chosen version", video.chosenVersionId.map { "\($0)" })
                }

                if !video.versions.isEmpty {
                    Section("Versions") {
                        ForEach(video.versions) { v in
                            row(v.label ?? "Version \(v.id)",
                                "\(v.status)\(v.isChosen ? " (chosen)" : "")")
                        }
                    }
                }

                if !video.subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        ForEach(video.subtitleTracks, id: \.language) { t in
                            row(t.language, subtitleDetail(t))
                        }
                    }
                }

                Section("Local storage") {
                    row("Cache state", cacheStateLabel)
                    row("File path", localFileURL?.path)
                    row("File size", fileSize(localFileURL))
                    row("Preview path", cachedPreviewURL?.path)
                    row("Preview size", fileSize(cachedPreviewURL))
                }
            }
            .navigationTitle("Video Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).textSelection(.enabled)
            }
        }
    }

    private var cacheStateLabel: String {
        switch cacheState {
        case .cached: return "Cached"
        case .notCached: return "Not cached"
        case .downloading(let p): return "Downloading (\(Int(p * 100))%)"
        }
    }

    private func subtitleDetail(_ t: SubtitleTrack) -> String {
        var parts = [t.name]
        if t.default { parts.append("default") }
        if t.forced { parts.append("forced") }
        return parts.joined(separator: ", ")
    }

    private func fileSize(_ url: URL?) -> String? {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
