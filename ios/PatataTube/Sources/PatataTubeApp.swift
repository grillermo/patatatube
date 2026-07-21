// ios/PatataTube/Sources/PatataTubeApp.swift
import SwiftUI
import Capture

@main
struct PatataTubeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Logger.start(
            withAPIKey: "GiDZTDyGAIXregVT4+YK7n/iskOtnE+sDmoxpMpusDaGACILRVdwMVdOWUFDeFEouAw=",
            sessionStrategy: .fixed()
        )
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
                    if phase == .active { model.cache.resumeInterrupted() }
                }
        }
    }
}

struct RootView: View {
    var body: some View { VideoGridView() }
}
