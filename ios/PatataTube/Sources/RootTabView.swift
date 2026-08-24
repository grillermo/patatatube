// ios/PatataTube/Sources/RootTabView.swift
import SwiftUI
import PatataTubeKit

/// The app's root: three media types, each with its own navigation stack.
///
/// `VideoStore.feed` is still the one source of truth for what is loaded, so
/// selecting a tab does exactly what the old segmented picker did — it calls
/// `switchFeed`. The Videos tab is the exception: its root is a group screen
/// that loads nothing, so it only switches the feed when a group is already
/// open beneath it.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore
    @State private var selection: MediaTab = .videos
    @State private var activation: MediaTab?

    var body: some View {
        TabView(selection: selectionBinding) {
            VideoGridView(tab: .videos, groups: model.groups, api: model.api, selectedTab: selection, activation: activation)
                .tabItem { Label("Videos", systemImage: "play.rectangle.on.rectangle") }
                .tag(MediaTab.videos)
            VideoGridView(tab: .tv, groups: model.groups, api: model.api, selectedTab: selection, activation: activation)
                .tabItem { Label("TV", systemImage: "tv") }
                .tag(MediaTab.tv)
            VideoGridView(tab: .movies, groups: model.groups, api: model.api, selectedTab: selection, activation: activation)
                .tabItem { Label("Movies", systemImage: "film") }
                .tag(MediaTab.movies)
        }
        // The restore button on the PiP float re-opens the full-screen player.
        // It lives at the root rather than in a grid because all three grids
        // exist at once and only one presentation may answer.
        .modifier(PictureInPictureRestoreCover(pip: model.pip, audio: model.audio))
        .onAppear {
            // Launched into the web bridge: stay on the default tab until the
            // bridge is dismissed, so the shortcut doesn't drop the user back
            // into last session's section first.
            guard !model.deferRestorationIfWebLaunch() else { return }
            selection = model.restorationStore.load().tab ?? .videos
        }
        .onChange(of: model.restorationReleases) { _, _ in
            selection = model.restorationStore.load().tab ?? .videos
        }
        .onChange(of: selection) { _, newValue in
            DevLog.event(.nav, "tab selected", ["tab": newValue.rawValue])
            guard let feed = newValue.feed, store.feed != feed else { return }
            Task { await store.switchFeed(to: feed) }
        }
    }

    /// Separate so the session is observed: `AppModel` doesn't republish when
    /// its `PiPSession` changes, so `RootTabView` alone would never re-render.
    private struct PictureInPictureRestoreCover: ViewModifier {
        @ObservedObject var pip: PiPSession
        let audio: AudioQueuePlayer

        func body(content: Content) -> some View {
            content
                // A second full-screen-player presentation site (Task 6 only
                // covered the grid's own `startPlayback`), so the "one audio
                // source at a time" constraint has to be enforced here too:
                // list audio may have started while the PiP float was up.
                .onChange(of: pip.restoreRequest) { _, newValue in
                    guard newValue != nil else { return }
                    audio.stop()
                }
                .fullScreenCover(item: $pip.restoreRequest) { request in
                    VideoPlayerView(
                        videos: request.videos, startIndex: request.startIndex,
                        sleepMode: request.sleepMode, randomize: pip.restoreRandomize,
                        startSecs: request.startSecs, autoplayScope: pip.restoreScope
                    )
                }
        }
    }

    private var selectionBinding: Binding<MediaTab> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                selection = newValue
                activation = newValue
            }
        )
    }
}
