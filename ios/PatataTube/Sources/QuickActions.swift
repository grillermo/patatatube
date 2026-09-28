// ios/PatataTube/Sources/QuickActions.swift
import UIKit

/// The home-screen quick actions. Raw value matches the
/// `UIApplicationShortcutItem.type` declared in project.yml.
enum QuickAction: String {
    case clearVideos = "com.patatatube.clearVideos"
    case clearCovers = "com.patatatube.clearCovers"
    case clearLists = "com.patatatube.clearLists"
    case resetSettings = "com.patatatube.resetSettings"
    case clearRestoration = "com.patatatube.clearRestoration"
    case installLatest = "com.patatatube.app.install-latest"

    init?(shortcutType: String) {
        self.init(rawValue: shortcutType)
    }

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(shortcutType: shortcutItem.type)
    }

    /// A link the scene delegate opens instead of routing to AppModel. For
    /// Install Latest it is the install page's own itms-services link:
    /// `./deploy` republishes the OTA manifest under this pinned name on every
    /// release, so it always installs the newest build.
    var url: URL? {
        switch self {
        case .installLatest:
            URL(string: "itms-services://?action=download-manifest&url=https://files.chiq.me/files/patatatube-manifest.plist")
        default:
            nil
        }
    }
}

/// Bridges shortcut delivery (scene delegate, non-SwiftUI) into SwiftUI.
/// RootView observes `pending` and dispatches to AppModel.
@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pending: QuickAction?
    private init() {}
}

/// Programmatically installed via AppDelegate.configurationForConnecting so
/// SwiftUI's WindowGroup still owns the window; this only forwards shortcuts.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// A link-opening action waiting for the scene to become active: opening
    /// an itms-services link before then is unreliable.
    private var pendingURL: URL?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let item = connectionOptions.shortcutItem,
              let action = QuickAction(shortcutItem: item) else { return }
        if let url = action.url {
            pendingURL = url
            return
        }
        // Synchronous on purpose: the launch views read `pending` in their
        // first `.task`/`onAppear` to decide whether to restore, and a
        // hop through `Task` can land after that.
        MainActor.assumeIsolated { QuickActionRouter.shared.pending = action }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let url = pendingURL else { return }
        pendingURL = nil
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = QuickAction(shortcutItem: shortcutItem) else {
            completionHandler(false)
            return
        }
        if let url = action.url {
            // Delivered while the scene is still becoming active; if it
            // already is, no sceneDidBecomeActive follows to open it.
            if windowScene.activationState == .foregroundActive {
                MainActor.assumeIsolated { UIApplication.shared.open(url) }
            } else {
                pendingURL = url
            }
            completionHandler(true)
            return
        }
        Task { @MainActor in QuickActionRouter.shared.pending = action }
        completionHandler(true)
    }
}
