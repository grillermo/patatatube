// ios/PatataTube/Sources/AboutView.swift
import SwiftUI

/// The options menu's "About" sheet: logo, name, version and copyright.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// "2.6.1 (179)" — read from the bundle, so it always matches the build
    /// `./deploy` stamped into project.yml.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image("Logo")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)

                Text("PatataTube")
                    .font(.title.bold())

                Text(Self.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    Text("Guillermo Siliceo")
                    Text("© 2026 Guillermo Siliceo. All rights reserved.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationSizing(.form)
    }
}
