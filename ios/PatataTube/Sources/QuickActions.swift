// ios/PatataTube/Sources/QuickActions.swift
import PatataTubeKit
import UIKit

/// The home-screen quick actions. Raw value is the `UIApplicationShortcutItem.type`.
/// Clear All is static (declared in project.yml). Install Latest is registered
/// at launch, and only by builds that ./deploy made (see `dynamicActions`).
enum QuickAction: String {
    case clearAll = "com.patatatube.clearAll"
    case installLatest = "com.patatatube.app.install-latest"

    /// Info.plist key that ./deploy fills with its fixed OTA manifest URL, passed
    /// as an xcodebuild command-line setting (an xcconfig would read the `//`).
    static let otaManifestURLInfoKey = "PatataTubeOTAManifestURL"

    init?(shortcutType: String) {
        self.init(rawValue: shortcutType)
    }

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(shortcutType: shortcutItem.type)
    }

    /// Actions registered as dynamic shortcut items at launch. Builds made
    /// outside ./deploy carry no manifest URL, so they offer no Install Latest:
    /// there is no release for them to install.
    static func dynamicActions(infoDictionary: [String: Any]?) -> [QuickAction] {
        otaManifestURL(infoDictionary: infoDictionary) == nil ? [] : [.installLatest]
    }

    /// A link the scene delegate opens instead of routing to AppModel. For
    /// Install Latest it is the install page's own itms-services link: iOS asks
    /// to install straight away, and ./deploy republishes the manifest under the
    /// same name on every release, so it always installs the newest build.
    func url(infoDictionary: [String: Any]?) -> URL? {
        switch self {
        case .installLatest:
            Self.otaManifestURL(infoDictionary: infoDictionary).flatMap {
                URL(string: "itms-services://?action=download-manifest&url=\($0.absoluteString)")
            }
        case .clearAll:
            nil
        }
    }

    /// iOS replaces the bundle under a running app, which crashes it, and only
    /// starts the install once you leave the app. So after the prompt is up the
    /// app exits on its own.
    var exitsAfterOpening: Bool { self == .installLatest }

    var dynamicShortcutItem: UIApplicationShortcutItem? {
        switch self {
        case .installLatest:
            UIApplicationShortcutItem(
                type: rawValue, localizedTitle: "Install Latest", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app")
            )
        case .clearAll:
            nil
        }
    }

    private static func otaManifestURL(infoDictionary: [String: Any]?) -> URL? {
        guard let value = infoDictionary?[otaManifestURLInfoKey] as? String, !value.isEmpty else { return nil }
        return URL(string: value)
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
    private var pendingLink: (url: URL, action: QuickAction)?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let item = connectionOptions.shortcutItem,
              let action = QuickAction(shortcutItem: item) else { return }
        if let url = action.url(infoDictionary: Bundle.main.infoDictionary) {
            pendingLink = (url, action)
            return
        }
        // Synchronous on purpose: the launch views read `pending` in their
        // first `.task`/`onAppear` to decide whether to restore, and a
        // hop through `Task` can land after that.
        MainActor.assumeIsolated { QuickActionRouter.shared.pending = action }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let link = pendingLink else { return }
        pendingLink = nil
        MainActor.assumeIsolated { Self.open(link.url, for: link.action) }
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
        if let url = action.url(infoDictionary: Bundle.main.infoDictionary) {
            // Delivered while the scene is still becoming active; if it
            // already is, no sceneDidBecomeActive follows to open it.
            if windowScene.activationState == .foregroundActive {
                MainActor.assumeIsolated { Self.open(url, for: action) }
            } else {
                pendingLink = (url, action)
            }
            completionHandler(true)
            return
        }
        Task { @MainActor in QuickActionRouter.shared.pending = action }
        completionHandler(true)
    }

    @MainActor
    private static func open(_ url: URL, for action: QuickAction) {
        UIApplication.shared.open(url) { opened in
            guard opened, action.exitsAfterOpening else { return }
            // Give the install prompt time to appear, then leave so iOS can
            // replace the bundle and start the install.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DevLog.flush()
                exit(0)
            }
        }
    }
}
