// ios/PatataTube/Sources/UploadView.swift
import SwiftUI
import PatataTubeKit

struct UploadView: View {
    @EnvironmentObject var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Video URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .navigationTitle("Add Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        submitting = true
                        Task {
                            await store.upload(url: urlText.trimmingCharacters(in: .whitespaces))
                            submitting = false
                            dismiss()
                        }
                    }
                    .disabled(urlText.isEmpty || submitting)
                }
            }
        }
    }
}
