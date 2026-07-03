// ios/PatataTube/Sources/PatataTubeApp.swift
import SwiftUI

@main
struct PatataTubeApp: App {
    @StateObject private var model = AppModel()

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
