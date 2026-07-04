// ios/PatataTube/Sources/SettingsView.swift
import SwiftUI
import PatataTubeKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL (https://…)", text: $model.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Upload token", text: $model.tokenText)
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testOK ? .green : .red)
                    }
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

    private func testConnection() {
        model.saveSettings()
        testing = true
        testResult = nil
        Task {
            do {
                _ = try await model.api.checkAuth()
                testOK = true
                testResult = "Connected — token is valid."
            } catch let APIError.badStatus(code) {
                testOK = false
                testResult = code == 401
                    ? "Token rejected (401)."
                    : "Server error (\(code))."
            } catch APIError.notConfigured {
                testOK = false
                testResult = "Set a base URL and token first."
            } catch {
                testOK = false
                testResult = "Could not reach server."
            }
            testing = false
        }
    }
}
