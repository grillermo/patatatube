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

// Temporary placeholder replaced in Task 9.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Text("PatataTube").font(.largeTitle)
            Text(model.credentials.baseURL?.absoluteString ?? "No server configured")
                .foregroundStyle(.secondary)
        }
    }
}
