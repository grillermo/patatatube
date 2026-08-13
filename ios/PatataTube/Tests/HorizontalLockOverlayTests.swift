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
struct HorizontalLockOverlayTests {
    @Test func buttonIsPositionedTwentyPercentDownThePlayer() {
        #expect(HorizontalLockOverlay.verticalOffsetFraction == 0.20)
    }

    @Test func unlockedAndLockedStatesUseAccessibleSystemSymbols() throws {
        var toggles = 0
        let unlocked = HorizontalLockOverlay(
            isHorizontal: false, isVisible: true, isBlocked: false,
            onToggle: { toggles += 1 }, isSleepOn: false, onToggleSleep: {}
        )
        let unlockedButton = try unlocked.inspect().find(
            ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Lock video orientation" }
        )
        #expect(try unlockedButton.find(ViewType.Image.self).actualImage().name() == "rotate.right")
        try unlockedButton.tap()
        #expect(toggles == 1)

        let locked = HorizontalLockOverlay(
            isHorizontal: true, isVisible: true, isBlocked: false,
            onToggle: {}, isSleepOn: false, onToggleSleep: {}
        )
        let lockedButton = try locked.inspect().find(
            ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Unlock video orientation" }
        )
        #expect(try lockedButton.find(ViewType.Image.self).actualImage().name() == "lock.rotation")
    }

    @Test func sleepButtonTogglesAndTintsWhenOn() throws {
        var sleepToggles = 0
        let off = HorizontalLockOverlay(
            isHorizontal: false, isVisible: true, isBlocked: false,
            onToggle: {}, isSleepOn: false, onToggleSleep: { sleepToggles += 1 }
        )
        let offButton = try off.inspect().find(
            ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Sleep after this video" }
        )
        #expect(try offButton.find(ViewType.Image.self).actualImage().name() == "moon.fill")
        try offButton.tap()
        #expect(sleepToggles == 1)

        let on = HorizontalLockOverlay(
            isHorizontal: false, isVisible: true, isBlocked: false,
            onToggle: {}, isSleepOn: true, onToggleSleep: {}
        )
        #expect(throws: Never.self) {
            try on.inspect().find(
                ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Cancel sleep after this video" }
            )
        }
    }

    @Test func blockedOverlayContainsNoButton() throws {
        let sut = HorizontalLockOverlay(
            isHorizontal: false, isVisible: true, isBlocked: true,
            onToggle: {}, isSleepOn: false, onToggleSleep: {}
        )
        #expect(throws: InspectionError.self) {
            try sut.inspect().find(ViewType.Button.self)
        }
    }

    @Test func hiddenOverlayContainsNoButton() throws {
        let sut = HorizontalLockOverlay(
            isHorizontal: false, isVisible: false, isBlocked: false,
            onToggle: {}, isSleepOn: false, onToggleSleep: {}
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
