// ios/PatataTube/Sources/MovieDetailView.swift
import SwiftUI
import PatataTubeKit

/// Pushed detail page for a single movie: poster, summary, play/download.
/// Play and download go through VideoGridView's closures so preparation state
/// and the error banner behave exactly as they do from the grid.
struct MovieDetailView: View {
    let video: Video
    let onPlay: (Video) -> Void
    /// Returns true only when the MP4 actually cached, so we don't paint a false checkmark.
    let onDownload: (Video) async -> Bool
    /// Pushing Downloads belongs to the stack's owner — this view declares
    /// no destinations of its own.
    var showDownloads: () -> Void = {}
    /// Only used to label the Group row in the Info sheet; Plex rows have none.
    var groups: [VideoGroup] = []

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    /// Forces the shared button to reread cache state after an explicit delete.
    @State private var downloadRefreshToken = 0
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var showingInfo = false

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
                                localFileURL: model.cache.cachedPreviewURL(for: currentVideo.id, path: currentVideo.previewUrl),
                                fill: false,
                                onNetworkLoad: { data in
                                    guard let path = currentVideo.previewUrl,
                                          model.cache.cachedPreviewURL(for: currentVideo.id, path: path) == nil else { return }
                                    model.cache.storePreview(data, for: currentVideo.id, path: path)
                                })
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

                    let subtitleTracks = currentVideo.subtitleTracks
                    if !subtitleTracks.isEmpty {
                        Picker("Subtitles", selection: Binding(
                            // Display-side resolution (gap #5): show the server's
                            // default track as selected while nothing is stored,
                            // without that ever reaching the player or the server.
                            get: {
                                currentVideo.effectiveSubtitleLang
                                    ?? (currentVideo.subtitleLang == nil ? currentVideo.defaultSubtitleLang ?? "" : "")
                            },
                            set: { lang in
                                // Compare against the optional, not `?? ""`: with
                                // nothing stored the displayed value is the default
                                // track, so picking "Off" ("") is a real change that
                                // a `?? ""` comparison would swallow.
                                guard lang != currentVideo.subtitleLang else { return }
                                Task { await store.chooseSubtitle(id: currentVideo.id, lang: lang) }
                            }
                        )) {
                            Text("Off").tag("")
                            ForEach(subtitleTracks, id: \.language) { t in
                                Text(t.name).tag(t.language)
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
                optionsMenu
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showUpload) { UploadView() }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(
                video: currentVideo,
                groups: groups,
                cacheState: model.cache.state(for: currentVideo.id,
                                              versionId: currentVideo.chosenVersionId),
                cachedPreviewURL: model.cache.cachedPreviewURL(for: currentVideo.id,
                                                              path: currentVideo.previewUrl),
                localFileURL: model.cache.localURL(for: currentVideo.id,
                                                   versionId: currentVideo.chosenVersionId)
            )
        }
    }

    /// The shared single-resource menu. Autoplay and randomize stay keyed by
    /// `store.feed`, the same scope the player gets when this page starts
    /// playback; Delete cached is this page's own extra.
    private var optionsMenu: some View {
        SingleOptionsMenu(
            scope: .feed(store.feed),
            actions: OptionsMenuActions(
                newVideo: { showUpload = true },
                downloads: { showDownloads() },
                settings: { showSettings = true }
            )
        ) {
            Button("Info", systemImage: "info.circle") { showingInfo = true }

            Button(role: .destructive) {
                model.cache.removeAllCached(id: currentVideo.id)
                // Flip the download button back to the arrow now,
                // instead of waiting for the 500ms cache poll.
                withAnimation { downloadRefreshToken &+= 1 }
            } label: {
                Label("Delete cached", systemImage: "trash")
            }
            .disabled(!model.cache.hasAnyCached(id: currentVideo.id))
        }
    }

    /// "spa" → "Spanish"; the source's title tag disambiguates when present.
    private func audioLabel(for track: AudioTrack) -> String {
        let name = Locale.current.localizedString(forLanguageCode: track.lang) ?? track.lang
        return track.title.isEmpty ? name : "\(name) — \(track.title)"
    }
}
