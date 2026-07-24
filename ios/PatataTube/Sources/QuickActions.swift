// ios/PatataTube/Sources/QuickActions.swift
import UIKit

/// The four home-screen quick actions. Raw value matches the
/// `UIApplicationShortcutItem.type` declared in project.yml.
enum QuickAction: String {
    case clearVideos = "com.patatatube.clearVideos"
    case clearCovers = "com.patatatube.clearCovers"
    case clearLists = "com.patatatube.clearLists"
    case resetSettings = "com.patatatube.resetSettings"

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
            Task { @MainActor in QuickActionRouter.shared.pending = action }
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
