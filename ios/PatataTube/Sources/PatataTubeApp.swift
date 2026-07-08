// ios/PatataTube/Sources/PatataTubeApp.swift
import SwiftUI
import Capture

@main
struct PatataTubeApp: App {
    @StateObject private var model = AppModel()

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
        }
    }
}

struct RootView: View {
    var body: some View { VideoGridView() }
}
