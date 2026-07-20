// ios/PatataTube/Sources/AutoplayToggle.swift
import SwiftUI

/// Toolbar switch for autoplay. Takes a binding rather than reading AppModel so
/// it stays testable in isolation; both toolbars pass `$model.autoplay`, so the
/// two switches always show the same value.
struct AutoplayToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Image("Autoplay")
                .renderingMode(.template)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Autoplay")
    }
}
