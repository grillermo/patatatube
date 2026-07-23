import Clocks
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

@MainActor
private func eventually(_ message: String, condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record(Comment(rawValue: message))
}

@Suite("Orientation lock overlay", .serialized)
@MainActor
struct OrientationLockOverlayTests {
    @Test func buttonIsPositionedTwentyPercentDownThePlayer() {
        #expect(OrientationLockOverlay.verticalOffsetFraction == 0.20)
    }

    @Test func unlockedAndLockedStatesUseAccessibleSystemSymbols() throws {
        var toggles = 0
        let unlocked = OrientationLockOverlay(
            isLocked: false, isVisible: true, isBlocked: false,
            onToggle: { toggles += 1 }
        )
        let unlockedButton = try unlocked.inspect().find(ViewType.Button.self)
        #expect(try unlockedButton.accessibilityLabel().string() == "Lock video orientation")
        #expect(try unlocked.inspect().find(ViewType.Image.self).actualImage().name() == "rotate.right")
        try unlockedButton.tap()
        #expect(toggles == 1)

        let locked = OrientationLockOverlay(
            isLocked: true, isVisible: true, isBlocked: false,
            onToggle: {}
        )
        #expect(try locked.inspect().find(ViewType.Button.self).accessibilityLabel().string() == "Unlock video orientation")
        #expect(try locked.inspect().find(ViewType.Image.self).actualImage().name() == "lock.rotation")
    }

    @Test func blockedOverlayContainsNoButton() throws {
        let sut = OrientationLockOverlay(
            isLocked: false, isVisible: true, isBlocked: true, onToggle: {}
        )
        #expect(throws: InspectionError.self) {
            try sut.inspect().find(ViewType.Button.self)
        }
    }

    @Test func hiddenOverlayContainsNoButton() throws {
        let sut = OrientationLockOverlay(
            isLocked: false, isVisible: false, isBlocked: false, onToggle: {}
        )
        #expect(throws: InspectionError.self) {
            try sut.inspect().find(ViewType.Button.self)
        }
    }

    @Test func visibilityAutoHidesAfterFourSeconds() async {
        let clock = TestClock()
        let sut = OrientationControlVisibility()
        sut.reveal(using: clock)
        #expect(sut.isVisible)
        await clock.advance(by: .seconds(3))
        #expect(sut.isVisible)
        await clock.advance(by: .seconds(1))
        await eventually("Control never auto-hid") { !sut.isVisible }
    }

    @Test func revealingAgainRefreshesTheTimeout() async {
        let clock = TestClock()
        let sut = OrientationControlVisibility()
        sut.reveal(using: clock)
        await clock.advance(by: .seconds(3))
        sut.reveal(using: clock)
        await clock.advance(by: .seconds(3))
        #expect(sut.isVisible)
        await clock.advance(by: .seconds(1))
        await eventually("Refreshed control never auto-hid") { !sut.isVisible }
    }
}
