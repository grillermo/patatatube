import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

/// Reference box so the test can observe writes through the binding.
@MainActor
private final class AutoplayBox {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor
private func makeToggle(_ box: AutoplayBox) -> AutoplayToggle {
    AutoplayToggle(isOn: Binding(get: { box.value }, set: { box.value = $0 }))
}

@Suite("Autoplay toggle", .serialized)
@MainActor
struct AutoplayToggleTests {
    @Test func rendersTheAutoplayIconAndReflectsTheBinding() throws {
        let box = AutoplayBox(false)
        let sut = makeToggle(box)

        let toggle = try sut.inspect().find(ViewType.Toggle.self)
        #expect(try toggle.isOn() == false)
        #expect(try toggle.accessibilityLabel().string() == "Autoplay")

        let image = try sut.inspect().find(ViewType.Image.self)
        #expect(try image.actualImage().name() == "Autoplay")
    }

    @Test func tappingWritesTheFlippedValueThroughTheBinding() throws {
        let box = AutoplayBox(false)

        try makeToggle(box).inspect().find(ViewType.Toggle.self).tap()
        #expect(box.value == true)

        try makeToggle(box).inspect().find(ViewType.Toggle.self).tap()
        #expect(box.value == false)
    }
}
