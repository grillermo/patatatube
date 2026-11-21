// ios/PatataTube/Sources/VideoCell.swift
import SwiftUI
import UIKit
import PatataTubeKit

struct VideoCell: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    /// Local file URL of the cached preview image, when the video is cached offline.
    var cachedPreviewURL: URL? = nil
    /// Called with the preview bytes when they came off the network, so the
    /// caller can persist them. `GroupsView` renders its cards from that disk
    /// cache alone, so without this a group's poster never has a local file.
    var onPreviewLoaded: ((Data) -> Void)? = nil
    /// Local file URL of the cached MP4 (may not exist on disk yet).
    var localFileURL: URL? = nil
    let groups: [VideoGroup]
    let onPlay: () -> Void
    /// Children-only corner button: play this one video, then sleep-lock.
    let onPlaySleep: () -> Void
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onDeleteCache: () -> Void
    let onSetGroup: (Int) -> Void
    let onDelete: () -> Void
    /// nil hides "Send to Yoto de Elisa".
    var onSendToYoto: (() -> Void)? = nil

    @State private var confirmingDelete = false
    @State private var showingInfo = false

    /// Play-and-sleep only makes sense on playable children's videos.
    private var isChildrenVideo: Bool {
        groups.first { $0.id == video.groupID }?.name == "children" && video.status == "done"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                ZStack {
                    Rectangle().fill(.black)
                    if video.previewUrl != nil || cachedPreviewURL != nil {
                        // scaledToFill previews report their covering size as their
                        // frame, which can exceed the cell; sizing the ZStack from the
                        // black rectangle and clipping here keeps every cell 16:9.
                        Rectangle().fill(.clear)
                            .overlay {
                                AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                            fill: true,
                                            onNetworkLoad: onPreviewLoaded)
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
            .logTap("play", ["video_id": "\(video.id)", "status": video.status])
            .overlay(alignment: .topTrailing) {
                if video.unwatched { UnwatchedDot().padding(8) }
            }
            .overlay(alignment: .bottom) { controlsStripe }

            Text(video.title ?? video.url)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, groups: groups, cacheState: cacheState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
    }

    /// The grey band along the poster's bottom edge. Only its buttons take
    /// taps: the band itself is not hit-testable, so the rest of it still plays.
    private var controlsStripe: some View {
        ZStack {
            HStack {
                DownloadButton(
                    identity: DownloadButtonIdentity(
                        videoID: video.id,
                        versionID: video.chosenVersionId
                    ),
                    currentCacheState: currentCacheState,
                    onDownload: onDownload,
                    onCancel: onCancel,
                    onDeleteCache: onDeleteCache
                )
                Spacer()
                Menu {
                    Button("Info", systemImage: "info.circle") { showingInfo = true }
                    Menu("Categorize", systemImage: "folder") {
                        ForEach(groups) { group in
                            Button(group.label) { onSetGroup(group.id) }
                        }
                    }
                    if let onSendToYoto, video.status == "done" {
                        Button("Send to Yoto de Elisa", systemImage: "headphones") { onSendToYoto() }
                    }
                    Divider()
                    Button("Delete video", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            if isChildrenVideo {
                Button(action: onPlaySleep) {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill")
                        Image(systemName: "moon.fill")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .tint(.white)
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background {
            Color(red: 60.0/255, green: 60.0/255, blue: 67.0/255).opacity(0.6)
                .allowsHitTesting(false)
        }
    }
}

/// A modal listing every locally-known field about a video, plus its on-disk
/// cache state (path + size). Read-only inspector reached from the "Info" menu.
struct VideoInfoView: View {
    let video: Video
    let groups: [VideoGroup]
    let cacheState: CacheState
    let cachedPreviewURL: URL?
    let localFileURL: URL?

    @Environment(\.dismiss) private var dismiss

    /// Identifies the row that was last copied, so only that one shows the
    /// "Copied" confirmation. Cleared by `copyResetTask` after a beat.
    @State private var copiedKey: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section("Video") {
                    row("ID", "\(video.id)")
                    row("Title", video.title)
                    row("URL", video.url)
                    row("Platform", video.platform)
                    // Only YouTube downloads carry one, and `row` hides an
                    // empty value, so uploads simply show no Channel line.
                    row("Channel", video.channel)
                    row("Source key", video.sourceKey)
                    row("Group", groups.first { $0.id == video.groupID }?.label ?? "Unsorted")
                    row("Position", video.position.map { "\($0)" })
                    row("Status", video.status)
                    row("Error", video.errorMsg)
                }

                Section("Playback") {
                    row("Stream path", video.streamPath)
                    row("HLS path", video.hlsPath)
                    row("Preview URL", video.previewUrl)
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
            let key = "\(label)|\(value)"
            let copied = copiedKey == key
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if copied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                Text(value).font(.body).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(copied ? Color.green.opacity(0.15) : nil)
            .onTapGesture { copy(value, key: key) }
        }
    }

    /// Tap-to-copy: pasteboard + haptic + a transient per-row confirmation.
    private func copy(_ value: String, key: String) {
        UIPasteboard.general.string = value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) { copiedKey = key }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copiedKey = nil }
        }
    }

    private var cacheStateLabel: String {
        switch cacheState {
        case .cached: return "Cached"
        case .notCached: return "Not cached"
        case .downloading(let p): return "Downloading (\(Int(p * 100))%)"
        }
    }

    private func fileSize(_ url: URL?) -> String? {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

