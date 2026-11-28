// ios/PatataTube/Sources/OptionsMenu.swift
import SwiftUI
import PatataTubeKit

/// Where a menu's Autoplay/Randomize toggles are stored: keyed by the
/// screen's `Feed`.
enum OptionsScope {
    case feed(Feed)
}

extension AppModel {
    func autoplayBinding(for scope: OptionsScope) -> Binding<Bool> {
        switch scope {
        case .feed(let feed): autoplayBinding(for: feed)
        }
    }

    func randomizeBinding(for scope: OptionsScope) -> Binding<Bool> {
        switch scope {
        case .feed(let feed): randomizeBinding(for: feed)
        }
    }
}

/// The callbacks every options menu needs. Each screen owns the sheets and the
/// navigation stack, so the menu only reports the intent.
struct OptionsMenuActions {
    var newVideo: () -> Void
    var downloads: () -> Void
    var settings: () -> Void

    init(newVideo: @escaping () -> Void,
         downloads: @escaping () -> Void,
         settings: @escaping () -> Void) {
        self.newVideo = newVideo
        self.downloads = downloads
        self.settings = settings
    }
}

/// A Download-all entry: the action plus whether it can run right now. The
/// screen computes eligibility, so it hands the resolved answer in.
struct DownloadAllOption {
    var isEnabled: Bool
    var accessibilityLabel: String?
    var action: () -> Void

    init(isEnabled: Bool, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }
}

// MARK: - Shared item blocks

/// The items every options menu opens with. **Add or remove a shared item
/// here, not in the call sites** — `ListOptionsMenu` builds from these
/// blocks.
private struct OptionsMenuHeader: View {
    let scope: OptionsScope
    let actions: OptionsMenuActions

    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            Button {
                actions.newVideo()
            } label: { Label("New video", systemImage: "plus") }

            Toggle(isOn: model.autoplayBinding(for: scope)) {
                Label("Autoplay", systemImage: "play.circle")
            }

            Toggle(isOn: model.randomizeBinding(for: scope)) {
                Label("Randomize", systemImage: "shuffle")
            }

            // A group setting, so only a group feed has one.
            if case .feed(.group(let id)) = scope {
                DisplayTitlesToggle(groups: model.groups, api: model.api, groupID: id)
                RememberPositionToggle(groups: model.groups, api: model.api, groupID: id)
                AutoDownloadToggle(store: model.autoDownload, groupID: id)
            }
        }
    }
}

/// The per-group "Display titles" switch. Its own view (rather than a `Toggle`
/// inline in the header) because it has to observe `GroupStore` — `AppModel`
/// holds that store as a plain `let`, so a change inside it doesn't republish
/// through `@EnvironmentObject`.
struct DisplayTitlesToggle: View {
    @ObservedObject var groups: GroupStore
    let api: APIClient
    let groupID: Int

    var body: some View {
        if let group = groups.group(id: groupID) {
            Toggle(isOn: Binding(
                get: { group.displayTitles },
                set: { set($0) }
            )) {
                Label("Display titles", systemImage: "textformat")
            }
        }
    }

    /// Optimistic like every other group write here: the grid redraws at once
    /// and a failed PATCH puts the switch back rather than leaving this device
    /// showing a setting the others never got.
    private func set(_ on: Bool) {
        groups.setDisplayTitles(id: groupID, on)
        Task {
            do {
                _ = try await api.setGroupDisplayTitles(id: groupID, on)
            } catch {
                await MainActor.run { groups.setDisplayTitles(id: groupID, !on) }
            }
        }
    }
}

/// The per-group "Remember position" switch: once on, every video in the
/// group offers to resume where playback got to. Same shape as
/// `DisplayTitlesToggle`, for the same reason.
struct RememberPositionToggle: View {
    @ObservedObject var groups: GroupStore
    let api: APIClient
    let groupID: Int

    var body: some View {
        if let group = groups.group(id: groupID) {
            Toggle(isOn: Binding(
                get: { group.rememberPosition },
                set: { set($0) }
            )) {
                Label("Remember position", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func set(_ on: Bool) {
        let id = groupID
        DevLog.event(.tap, "remember position toggled", ["group_id": "\(id)", "on": "\(on)"])
        groups.setRememberPosition(id: groupID, on)
        Task {
            do {
                let saved = try await api.setGroupRememberPosition(id: id, on)
                DevLog.event(.net, "remember position saved",
                             ["group_id": "\(id)", "sent": "\(on)", "server": "\(saved.rememberPosition)"])
            } catch {
                DevLog.error(error, "remember position PATCH failed", ["group_id": "\(id)", "on": "\(on)"])
                await MainActor.run { groups.setRememberPosition(id: groupID, !on) }
            }
        }
    }
}

/// The per-group "Download automatically" switch. Stored on this device only
/// (`AutoDownloadStore`); turning it on starts the first pass right away
/// instead of waiting for the next activation.
struct AutoDownloadToggle: View {
    @ObservedObject var store: AutoDownloadStore
    let groupID: Int

    @EnvironmentObject var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isOn(groupID) },
            set: { on in
                DevLog.event(.tap, "auto-download toggled", ["group_id": "\(groupID)", "on": "\(on)"])
                store.set(groupID, on)
                if on { model.runAutoDownloads() }
            }
        )) {
            Label("Download automatically", systemImage: "arrow.down.circle.dotted")
        }
    }
}

/// Downloads, then whatever the screen adds, then Settings and About under a
/// divider.
private struct OptionsMenuFooter<Extras: View>: View {
    let actions: OptionsMenuActions
    let downloadAll: DownloadAllOption?
    /// Unlike the other actions this is not the screen's: the About sheet has
    /// no per-screen state, so each menu shape presents it itself.
    let about: () -> Void
    @ViewBuilder let extras: Extras

    var body: some View {
        Group {
            if let downloadAll {
                Button {
                    downloadAll.action()
                } label: { Label("Download all", systemImage: "arrow.down.circle") }
                .disabled(!downloadAll.isEnabled)
                .accessibilityLabel(downloadAll.accessibilityLabel ?? "Download all")
            }

            Button {
                actions.downloads()
            } label: { Label("Downloads", systemImage: "arrow.down.circle") }

            extras

            Divider()

            Button {
                actions.settings()
            } label: { Label("Settings", systemImage: "gear") }

            Button {
                about()
            } label: { Label("About", systemImage: "info.circle") }
        }
    }
}

// MARK: - The menu

/// Options menu for a screen showing a *list* of videos (the grid, a group).
/// Carries Download all; `extras` is for items only one list
/// has, like the grid's cell-size steps.
struct ListOptionsMenu<Extras: View>: View {
    let scope: OptionsScope
    let actions: OptionsMenuActions
    let downloadAll: DownloadAllOption?
    /// Swaps the ellipsis for a spinner while a bulk download runs.
    var isBusy: Bool = false
    @ViewBuilder var extras: Extras

    @State private var showingAbout = false

    var body: some View {
        Menu {
            OptionsMenuHeader(scope: scope, actions: actions)
            Divider()
            OptionsMenuFooter(actions: actions, downloadAll: downloadAll,
                              about: { showingAbout = true }) { extras }
        } label: {
            OptionsMenuLabel(isBusy: isBusy)
        }
        .sheet(isPresented: $showingAbout) { AboutView() }
    }
}

extension ListOptionsMenu where Extras == EmptyView {
    init(scope: OptionsScope,
         actions: OptionsMenuActions,
         downloadAll: DownloadAllOption?,
         isBusy: Bool = false) {
        self.init(scope: scope,
                  actions: actions,
                  downloadAll: downloadAll,
                  isBusy: isBusy,
                  extras: { EmptyView() })
    }
}

private struct OptionsMenuLabel: View {
    var isBusy: Bool = false

    var body: some View {
        if isBusy {
            ProgressView()
        } else {
            Image(systemName: "ellipsis.circle")
        }
    }
}
