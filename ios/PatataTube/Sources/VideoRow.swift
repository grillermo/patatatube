// ios/PatataTube/Sources/VideoRow.swift
import SwiftUI
import PatataTubeKit

/// One video as a flat list row — the shape `defaultGrid` takes at its
/// densest setting, where a 120pt card is too small to read.
///
/// Everything left of the ellipsis plays. Every control the card carries in
/// its footer (download, version picker, play-and-sleep, server status) moves
/// into the menu, so the row itself is a thumbnail and a title. A download in
/// flight is therefore invisible until the menu is opened, and the percentage
/// in the label is a snapshot from when it opened — menus don't live-update.
/// That is the accepted trade for a clean row; the grid still shows progress.
struct VideoRow: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    var cachedPreviewURL: URL? = nil
    var onPreviewLoaded: ((Data) -> Void)? = nil
    var localFileURL: URL? = nil
    let groups: [VideoGroup]

    /// Audio-only playback status for this row. `.idle` everywhere except the
    /// group-detail list, whose rows play audio instead of presenting a player.
    var audioState: RowAudioState = .idle

    let onPlay: () -> Void
    let onPlaySleep: () -> Void
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onDeleteCache: () -> Void
    let onSetGroup: (Int) -> Void
    let onPromote: (PlexKind) -> Void
    let onChooseVersion: (Int) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var showingInfo = false
    @State private var downloading = false

    static let thumbWidth: CGFloat = 78
    static let thumbHeight: CGFloat = 44

    private var isChildrenVideo: Bool {
        groups.first { $0.id == video.groupID }?.name == "children" && video.status == "done"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    HStack(spacing: 12) {
                        thumbnail
                        Text(video.title ?? video.url)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .logTap("play", ["video_id": "\(video.id)", "status": video.status])

                menu
            }
            .padding(.vertical, 6)

            Divider()
        }
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, groups: groups, cacheState: cacheState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
    }

    /// Fixed 78x44 box for both aspect ratios, so titles line up across feeds.
    /// Plex posters are 2:3 and letterbox inside it rather than centre-cropping.
    /// In audio mode the thumbnail keeps rendering and takes a dimmed overlay
    /// carrying the play/pause glyph — the row's only playback control.
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil || cachedPreviewURL != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                    fill: !video.isPlexItem,
                                    onNetworkLoad: onPreviewLoaded)
                    }
                    .clipped()
            }
            audioOverlay
        }
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipped()
        .cornerRadius(4)
    }

    @ViewBuilder private var audioOverlay: some View {
        switch audioState {
        case .idle:
            EmptyView()
        case .loading:
            Color.black.opacity(0.45)
            ProgressView().tint(.white).scaleEffect(0.7)
        case .playing, .paused:
            Color.black.opacity(0.45)
            Image(systemName: audioState.overlaySystemImage ?? "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
    }

    private var menu: some View {
        Menu {
            downloadActions

            if isChildrenVideo {
                Button("Play and sleep", systemImage: "moon.fill") { onPlaySleep() }
            }

            Button("Info", systemImage: "info.circle") { showingInfo = true }

            if !video.isPlexItem {
                ForEach(groups) { group in
                    Button(group.label) { onSetGroup(group.id) }
                }
                Section("Move to Plex") {
                    ForEach(PlexKind.allCases, id: \.self) { kind in
                        Button(kind == .tv ? "TV" : "Movies") { onPromote(kind) }
                    }
                }
            }

            if video.versions.count > 1 {
                Section("Version") {
                    ForEach(video.versions) { version in
                        let chosen = version.id == (video.chosenVersionId ?? video.versions.first?.id)
                        Button {
                            onChooseVersion(version.id)
                        } label: {
                            if chosen {
                                Label(version.label ?? "Version \(version.id)",
                                      systemImage: "checkmark")
                            } else {
                                Text(version.label ?? "Version \(version.id)")
                            }
                        }
                    }
                }
            }

            if video.status != "done" {
                Button("Status: \(video.status)") {}.disabled(true)
            }

            Divider()
            Button("Delete video", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var downloadActions: some View {
        switch cacheState {
        case .notCached:
            Button("Download", systemImage: "arrow.down.circle") {
                guard !downloading else { return }
                downloading = true
                Task {
                    _ = await onDownload()
                    downloading = false
                }
            }
            .disabled(downloading)
        case .downloading(let progress):
            Button("Downloading \(Int(progress * 100))%") {}.disabled(true)
            Button("Cancel download", systemImage: "xmark.circle") { onCancel() }
        case .cached:
            Button("Delete download", systemImage: "trash") { onDeleteCache() }
        }
    }
}
