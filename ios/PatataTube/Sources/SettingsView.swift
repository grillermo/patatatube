// ios/PatataTube/Sources/SettingsView.swift
import SwiftUI
import PatataTubeKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL (https://…)", text: $model.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Upload token", text: $model.tokenText)
                }
                Section {
                    Button("Cache all videos") {
                        Task {
                            for video in model.store.videos {
                                if let url = model.streamURL(for: video) {
                                    try? await model.cache.download(id: video.id, from: url)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.saveSettings(); dismiss() }
                }
            }
        }
    }
}
