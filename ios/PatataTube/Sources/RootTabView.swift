// ios/PatataTube/Sources/RootTabView.swift
import SwiftUI
import PatataTubeKit

/// The app's root: three media types, each with its own navigation stack.
///
/// `VideoStore.filter` is still the one source of truth for what is loaded, so
/// selecting a tab does exactly what the old segmented picker did — it calls
/// `switchFilter`. The Videos tab is the exception: its root is a group screen
/// that loads nothing, so it only switches the filter when a group is already
/// open beneath it.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore
    @State private var selection: MediaTab = .videos
    @State private var activation: MediaTab?

    var body: some View {
        TabView(selection: selectionBinding) {
            VideoGridView(tab: .videos, selectedTab: selection, activation: activation)
                .tabItem { Label("Videos", systemImage: "play.rectangle.on.rectangle") }
                .tag(MediaTab.videos)
            VideoGridView(tab: .tv, selectedTab: selection, activation: activation)
                .tabItem { Label("TV", systemImage: "tv") }
                .tag(MediaTab.tv)
            VideoGridView(tab: .movies, selectedTab: selection, activation: activation)
                .tabItem { Label("Movies", systemImage: "film") }
                .tag(MediaTab.movies)
        }
        .onAppear {
            selection = model.restorationStore.load().tab ?? .videos
        }
        .onChange(of: selection) { _, newValue in
            DevLog.event(.nav, "tab selected", ["tab": newValue.rawValue])
            guard let filter = newValue.filter, store.filter != filter else { return }
            Task { await store.switchFilter(to: filter) }
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
