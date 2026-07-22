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

    /// Forces the shared button to reread cache state after an explicit delete.
    @State private var downloadRefreshToken = 0

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

                    DownloadButton(
                        identity: DownloadButtonIdentity(
                            videoID: currentVideo.id,
                            versionID: currentVideo.chosenVersionId,
                            audioLanguage: currentVideo.audioLang
                        ),
                        refreshToken: downloadRefreshToken,
                        currentCacheState: {
                            model.cache.state(
                                for: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        },
                        onDownload: { await onDownload(currentVideo) },
                        onCancel: {
                            model.cache.cancel(
                                id: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        },
                        onDeleteCache: {
                            model.cache.removeCached(
                                id: currentVideo.id,
                                versionId: currentVideo.chosenVersionId
                            )
                        }
                    )

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
                        withAnimation { downloadRefreshToken &+= 1 }
                    } label: {
                        Label("Delete cached", systemImage: "trash")
                    }
                    .disabled(!model.cache.hasAnyCached(id: currentVideo.id))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// "spa" → "Spanish"; the source's title tag disambiguates when present.
    private func audioLabel(for track: AudioTrack) -> String {
        let name = Locale.current.localizedString(forLanguageCode: track.lang) ?? track.lang
        return track.title.isEmpty ? name : "\(name) — \(track.title)"
    }
}
