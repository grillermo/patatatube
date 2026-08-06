// ios/PatataTube/Sources/OptionsMenu.swift
import SwiftUI
import PatataTubeKit

/// Where a menu's Autoplay/Randomize toggles are stored. A tab-level screen
/// keys them by its `Feed`; a per-show screen keys them by a named scope
/// (`AppModel.showScope`) so one show's settings don't leak into the tab's.
enum OptionsScope {
    case feed(Feed)
    case named(String)
}

extension AppModel {
    func autoplayBinding(for scope: OptionsScope) -> Binding<Bool> {
        switch scope {
        case .feed(let feed): autoplayBinding(for: feed)
        case .named(let name): autoplayBinding(for: name)
        }
    }

    func randomizeBinding(for scope: OptionsScope) -> Binding<Bool> {
        switch scope {
        case .feed(let feed): randomizeBinding(for: feed)
        case .named(let name): randomizeBinding(for: name)
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

/// A Download-all entry: the action plus whether it can run right now. The two
/// list screens compute eligibility differently (grid over the whole feed,
/// episodes over one show), so they hand the resolved answer in.
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
/// here, not in the call sites** — `ListOptionsMenu` and `SingleOptionsMenu`
/// are the only two shapes, and both build from these blocks.
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
        }
    }
}

/// Downloads, then whatever the screen adds, then Settings under a divider.
private struct OptionsMenuFooter<Extras: View>: View {
    let actions: OptionsMenuActions
    let downloadAll: DownloadAllOption?
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
        }
    }
}

// MARK: - The two shapes

/// Options menu for a screen showing a *list* of videos (the grid, a group, a
/// show's episodes). Carries Download all; `extras` is for items only one list
/// has, like the grid's cell-size steps.
struct ListOptionsMenu<Extras: View>: View {
    let scope: OptionsScope
    let actions: OptionsMenuActions
    let downloadAll: DownloadAllOption?
    /// Swaps the ellipsis for a spinner while a bulk download runs.
    var isBusy: Bool = false
    @ViewBuilder var extras: Extras

    var body: some View {
        Menu {
            OptionsMenuHeader(scope: scope, actions: actions)
            Divider()
            OptionsMenuFooter(actions: actions, downloadAll: downloadAll) { extras }
        } label: {
            OptionsMenuLabel(isBusy: isBusy)
        }
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

/// Options menu for a screen showing a *single* video (movie detail). No
/// Download all — there is nothing to download in bulk — and `extras` carries
/// the per-item entries, like Delete cached.
struct SingleOptionsMenu<Extras: View>: View {
    let scope: OptionsScope
    let actions: OptionsMenuActions
    @ViewBuilder var extras: Extras

    var body: some View {
        Menu {
            OptionsMenuHeader(scope: scope, actions: actions)
            Divider()
            OptionsMenuFooter(actions: actions, downloadAll: nil) { extras }
        } label: {
            OptionsMenuLabel()
        }
    }
}

extension SingleOptionsMenu where Extras == EmptyView {
    init(scope: OptionsScope, actions: OptionsMenuActions) {
        self.init(scope: scope, actions: actions, extras: { EmptyView() })
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
