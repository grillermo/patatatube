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
                        .onChange(of: model.baseURLText) { invalidateTest() }
                    SecureField("Upload token", text: $model.tokenText)
                        .onChange(of: model.tokenText) { invalidateTest() }
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
                Section("Downloads") {
                    Stepper(
                        value: $model.downloadStreamCount,
                        in: DownloadStreamSettings.allowedCounts
                    ) {
                        LabeledContent(
                            "Streams per video",
                            value: "\(model.downloadStreamCount)"
                        )
                    }
                    Stepper(
                        value: $model.downloadConcurrency,
                        in: SimultaneousDownloadSettings.allowedCounts
                    ) {
                        LabeledContent(
                            "Simultaneous downloads",
                            value: "\(model.downloadConcurrency)"
                        )
                    }
                }

                Section {
                    Button("Cache all videos") {
                        Task {
                            await withTaskGroup(of: Void.self) { group in
                                for video in model.store.videos {
                                    guard let url = model.streamURL(for: video) else { continue }
                                    let preview = video.previewUrl.flatMap(URL.init(string:))
                                    let versionId = video.chosenVersionId
                                    let id = video.id
                                    let streamCount = model.downloadStreamCount
                                    let token = model.credentials.token
                                    group.addTask {
                                        try? await model.cache.download(
                                            id: id, versionId: versionId, from: url,
                                            preview: preview, bearerToken: token,
                                            streamCount: streamCount
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.saveSettings()
                        if testOK { Task { await model.store.load() } }
                        dismiss()
                    }
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

    /// Editing the server fields invalidates a prior successful test so "Done"
    /// only reloads when the shown values were the ones actually tested.
    private func invalidateTest() {
        testOK = false
        testResult = nil
    }
}
