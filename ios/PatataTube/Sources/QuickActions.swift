// ios/PatataTube/Sources/QuickActions.swift
import UIKit

/// The home-screen quick actions. Raw value matches the
/// `UIApplicationShortcutItem.type` declared in project.yml.
enum QuickAction: String {
    case openWeb = "com.patatatube.openWeb"
    case clearVideos = "com.patatatube.clearVideos"
    case clearCovers = "com.patatatube.clearCovers"
    case clearLists = "com.patatatube.clearLists"
    case resetSettings = "com.patatatube.resetSettings"
    case clearRestoration = "com.patatatube.clearRestoration"

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(rawValue: shortcutItem.type)
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
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem,
           let action = QuickAction(shortcutItem: item) {
            // Synchronous on purpose: the launch views read `pending` in their
            // first `.task`/`onAppear` to decide whether to restore, and a
            // hop through `Task` can land after that.
            MainActor.assumeIsolated { QuickActionRouter.shared.pending = action }
        }
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
        Task { @MainActor in QuickActionRouter.shared.pending = action }
        completionHandler(true)
    }
}
