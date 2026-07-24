// ios/PatataTube/Sources/PatataTubeApp.swift
import SwiftUI
import Sentry

import Capture

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLockRegistry.shared.supportedOrientations(
            for: window?.windowScene,
            default: OrientationLockCoordinator.normalMask
        )
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

@main
struct PatataTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SentrySDK.start { options in
            options.dsn = "https://de3e08718ecce35b4b92a8519ec40a79@o4511260455796736.ingest.us.sentry.io/4511786930798597"

            // Adds IP for users.
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = true

            // Set tracesSampleRate to 1.0 to capture 100% of transactions for performance monitoring.
            // We recommend adjusting this value in production.
            options.tracesSampleRate = 1.0

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = {
                $0.sessionSampleRate = 1.0 // We recommend adjusting this value in production.
                $0.lifecycle = .trace
            }

            // Uncomment the following lines to add more data to your events
            // options.attachScreenshot = true // This adds a screenshot to the error events
            // options.attachViewHierarchy = true // This adds the view hierarchy to the error events
            
            // Enable experimental logging features
            options.experimental.enableLogs = true
        }
        // Remove the next line after confirming that your Sentry integration is working.
        SentrySDK.capture(message: "This app uses Sentry! :)")

        Logger.start(
            withAPIKey: "GiDZTDyGAIXregVT4+YK7n/iskOtnE+sDmoxpMpusDaGACILRVdwMVdOWUFDeFEouAw=",
            sessionStrategy: .fixed()
        )

        // Memory telemetry for the OOM / watchdog terminations (PATATATUBE-6, -2).
        MainActor.assumeIsolated { MemoryProbe.installMemoryWarningObserver() }
        MemoryProbe.snapshot("app-launch")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .onChange(of: scenePhase) { _, phase in
                    // Downloads use a foreground session, so they stall when the
                    // app is suspended. Resume them from persisted resume data
                    // whenever we come back to the foreground (and on launch).
                    if phase == .active {
                        model.cache.resumeInterrupted(bearerToken: model.credentials.token)
                    }
                }
                .onReceive(QuickActionRouter.shared.$pending.compactMap { $0 }) { action in
                    Task {
                        await model.handle(action)
                        QuickActionRouter.shared.pending = nil
                    }
                }
        }
    }
}

struct RootView: View {
    var body: some View { VideoGridView() }
}
