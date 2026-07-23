# Player Orientation Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a player-only toggle that captures the displayed orientation, ignores later device rotation until unlocked, and appears alongside AVKit's controls.

**Architecture:** A pure `OrientationLockState` models valid device orientations and masks, while a main-actor `OrientationLockCoordinator` bridges that state to UIKit's application orientation callback and `UIWindowScene` geometry requests. A testable visibility object drives a small SwiftUI lock-button overlay; `PlayerViewController` reports non-cancelling taps so `VideoPlayerView` can reveal the overlay without replacing AVKit's native controls.

**Tech Stack:** Swift 6, SwiftUI, UIKit, AVKit, Swift Testing, ViewInspector, Point-Free Clocks, XcodeGen; iOS 17.0+

## Global Constraints

- Support iPhone and iPad on iOS 17.0 or later.
- Preserve portrait and both landscape orientations on iPhone.
- Preserve portrait, portrait upside down, and both landscape orientations on iPad.
- The lock is off for each new player presentation, survives autoplay item changes, and resets on dismissal.
- The toggle is independent of Control Center Rotation Lock.
- The toggle is available in normal and play-and-sleep playback; the completed sleep overlay blocks it.
- Do not replace AVKit's native playback controls or use private UIKit/SpringBoard APIs.
- Do not add third-party dependencies.

---

### Task 1: Orientation policy and UIKit coordinator

**Files:**
- Create: `ios/PatataTube/Sources/OrientationLockCoordinator.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift`
- Create: `ios/PatataTube/Tests/OrientationLockCoordinatorTests.swift`

**Interfaces:**
- Consumes: `UIApplicationDelegate.application(_:supportedInterfaceOrientationsFor:)`, `UIWindowScene.interfaceOrientation`, `UIDevice.orientation`, and `UIWindowScene.requestGeometryUpdate(_:)`.
- Produces: `OrientationLockState`, `OrientationLockCoordinator.shared`, `isLocked: Bool`, `supportedOrientations: UIInterfaceOrientationMask`, `beginPlayerSession(in:)`, `toggle(in:)`, and `endPlayerSession(in:)`.

- [ ] **Step 1: Write failing tests for the pure orientation state**

Create `ios/PatataTube/Tests/OrientationLockCoordinatorTests.swift` with these cases:

```swift
import Testing
import UIKit
@testable import PatataTube

@Suite("Player orientation lock state")
struct OrientationLockCoordinatorTests {
    @Test func phoneStartsUnlockedWithItsConfiguredMask() {
        let sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func lockCapturesTheDisplayedInterfaceOrientation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        #expect(sut.lock(to: .landscapeLeft))
        #expect(sut.isLocked)
        #expect(sut.supportedMask == .landscapeLeft)
    }

    @Test func invalidInterfaceOrientationCannotLock() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        #expect(!sut.lock(to: .unknown))
        #expect(!sut.isLocked)
    }

    @Test func rotationWhileLockedIsRememberedWithoutChangingTheMask() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .portrait)
        sut.record(deviceOrientation: .landscapeLeft)
        #expect(sut.supportedMask == .portrait)
        #expect(sut.latestRequestedInterfaceOrientation == .landscapeRight)
    }

    @Test func faceUpFaceDownAndUnknownReadingsAreIgnored() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)
        sut.record(deviceOrientation: .faceUp)
        sut.record(deviceOrientation: .faceDown)
        sut.record(deviceOrientation: .unknown)
        #expect(sut.latestRequestedInterfaceOrientation == .landscapeLeft)
    }

    @Test func unlockRestoresNormalMaskAndReturnsLatestSupportedOrientation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .portrait)
        sut.record(deviceOrientation: .landscapeRight)
        #expect(sut.unlock() == .landscapeLeft)
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func phoneRejectsUpsideDownButPadAcceptsIt() {
        var phone = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        phone.record(deviceOrientation: .portraitUpsideDown)
        #expect(phone.latestRequestedInterfaceOrientation == nil)

        var pad = OrientationLockState(normalMask: .all)
        pad.record(deviceOrientation: .portraitUpsideDown)
        #expect(pad.latestRequestedInterfaceOrientation == .portraitUpsideDown)
    }

    @Test func resetClearsLockAndPendingRotation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .landscapeRight)
        sut.record(deviceOrientation: .portrait)
        sut.reset()
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
        #expect(sut.latestRequestedInterfaceOrientation == nil)
    }
}
```

- [ ] **Step 2: Run the new suite and verify it fails**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/OrientationLockCoordinatorTests
```

Expected: build failure because `OrientationLockState` does not exist.

- [ ] **Step 3: Implement the pure state and runtime coordinator**

Create `ios/PatataTube/Sources/OrientationLockCoordinator.swift`. Implement:

```swift
import Combine
import UIKit

struct OrientationLockState {
    let normalMask: UIInterfaceOrientationMask
    private(set) var supportedMask: UIInterfaceOrientationMask
    private(set) var lockedOrientation: UIInterfaceOrientation?
    private(set) var latestRequestedInterfaceOrientation: UIInterfaceOrientation?

    var isLocked: Bool { lockedOrientation != nil }

    init(normalMask: UIInterfaceOrientationMask) {
        self.normalMask = normalMask
        self.supportedMask = normalMask
    }

    mutating func record(deviceOrientation: UIDeviceOrientation) {
        guard let interfaceOrientation = deviceOrientation.interfaceOrientation,
              normalMask.contains(interfaceOrientation.mask) else { return }
        latestRequestedInterfaceOrientation = interfaceOrientation
    }

    @discardableResult
    mutating func lock(to orientation: UIInterfaceOrientation) -> Bool {
        guard orientation != .unknown, normalMask.contains(orientation.mask) else { return false }
        lockedOrientation = orientation
        supportedMask = orientation.mask
        return true
    }

    mutating func unlock() -> UIInterfaceOrientation? {
        lockedOrientation = nil
        supportedMask = normalMask
        return latestRequestedInterfaceOrientation
    }

    mutating func reset() {
        lockedOrientation = nil
        latestRequestedInterfaceOrientation = nil
        supportedMask = normalMask
    }
}

private extension UIDeviceOrientation {
    var interfaceOrientation: UIInterfaceOrientation? {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
    }
}

@MainActor
final class OrientationLockCoordinator: ObservableObject {
    static let shared = OrientationLockCoordinator()

    @Published private(set) var isLocked = false
    private var state = OrientationLockState(normalMask: Self.normalMask)
    private weak var activeScene: UIWindowScene?
    private var orientationObserver: NSObjectProtocol?

    var supportedOrientations: UIInterfaceOrientationMask { state.supportedMask }

    private static var normalMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .all
            : [.portrait, .landscapeLeft, .landscapeRight]
    }

    func beginPlayerSession(in scene: UIWindowScene?) {
        endObservation()
        state.reset()
        isLocked = false
        activeScene = scene
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        state.record(deviceOrientation: UIDevice.current.orientation)
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state.record(deviceOrientation: UIDevice.current.orientation)
            }
        }
    }

    func toggle(in scene: UIWindowScene?) {
        if let scene { activeScene = scene }
        guard let activeScene else { return }
        if state.isLocked {
            let pending = state.unlock()
            isLocked = false
            applySupportedOrientations(in: activeScene, requested: pending)
        } else if state.lock(to: activeScene.interfaceOrientation) {
            isLocked = true
            applySupportedOrientations(in: activeScene, requested: activeScene.interfaceOrientation)
        }
    }

    func endPlayerSession(in scene: UIWindowScene?) {
        if let scene { activeScene = scene }
        let pending = state.unlock()
        isLocked = false
        if let activeScene { applySupportedOrientations(in: activeScene, requested: pending) }
        state.reset()
        activeScene = nil
        endObservation()
    }

    private func applySupportedOrientations(
        in scene: UIWindowScene,
        requested: UIInterfaceOrientation?
    ) {
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let requested else { return }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: requested.mask)
        ) { _ in
            // Non-fatal: the supported mask remains authoritative and playback continues.
        }
    }

    private func endObservation() {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        orientationObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: \.isKeyWindow) }
}
```

- [ ] **Step 4: Wire the application orientation callback**

Add this delegate above `PatataTubeApp` and attach it to the app:

```swift
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLockCoordinator.shared.supportedOrientations
    }
}

@main
struct PatataTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Keep the existing properties and body unchanged.
}
```

- [ ] **Step 5: Run the focused tests and app build**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/OrientationLockCoordinatorTests
rtk xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: eight orientation-state tests pass and the app builds with no errors.

- [ ] **Step 6: Commit the orientation policy**

```bash
rtk git add ios/PatataTube/Sources/OrientationLockCoordinator.swift ios/PatataTube/Sources/PatataTubeApp.swift ios/PatataTube/Tests/OrientationLockCoordinatorTests.swift
rtk git commit -m "feat(ios): add player orientation lock policy"
```

---

### Task 2: Accessible auto-hiding orientation control

**Files:**
- Create: `ios/PatataTube/Sources/OrientationLockOverlay.swift`
- Create: `ios/PatataTube/Tests/OrientationLockOverlayTests.swift`

**Interfaces:**
- Consumes: `isLocked: Bool`, `isVisible: Bool`, `isBlocked: Bool`, `onToggle: () -> Void`, and a `Clock` used by the visibility state.
- Produces: `OrientationControlVisibility.reveal(using:)`, `hide()`, and `OrientationLockOverlay`, a top-trailing control that never renders while hidden or blocked.

- [ ] **Step 1: Write failing rendering, interaction, blocking, and timeout tests**

Create `ios/PatataTube/Tests/OrientationLockOverlayTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the overlay suite and verify it fails**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/OrientationLockOverlayTests
```

Expected: build failure because `OrientationLockOverlay` does not exist.

- [ ] **Step 3: Implement the overlay**

Create `ios/PatataTube/Sources/OrientationLockOverlay.swift`:

```swift
import Combine
import SwiftUI

@MainActor
final class OrientationControlVisibility: ObservableObject {
    @Published private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?

    func reveal() {
        reveal(using: ContinuousClock())
    }

    func reveal<C: Clock>(using clock: C) where C.Duration == Duration {
        hideTask?.cancel()
        isVisible = true
        hideTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false
    }
}

struct OrientationLockOverlay: View {
    let isLocked: Bool
    let isVisible: Bool
    let isBlocked: Bool
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isVisible && !isBlocked {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: isLocked ? "lock.rotation" : "rotate.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isLocked ? Color.accentColor : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLocked ? "Unlock video orientation" : "Lock video orientation")
                .padding(16)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
```

Do not add a background or content shape to the full-screen container; only the visible 44-point button may intercept touches.

- [ ] **Step 4: Run the focused overlay tests**

Run the same focused command from Step 2.

Expected: all overlay rendering, interaction, blocking, timeout, and timeout-refresh tests pass.

- [ ] **Step 5: Commit the overlay**

```bash
rtk git add ios/PatataTube/Sources/OrientationLockOverlay.swift ios/PatataTube/Tests/OrientationLockOverlayTests.swift
rtk git commit -m "feat(ios): add orientation lock player control"
```

---

### Task 3: AVKit tap and player lifecycle integration

**Files:**
- Modify: `ios/PatataTube/Sources/PlayerViewController.swift`
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`
- Create: `ios/PatataTube/Tests/PlayerViewControllerTests.swift`
- Modify: `ios/README.md`

**Interfaces:**
- Consumes: `OrientationLockCoordinator.shared`, `OrientationLockOverlay`, and `onPlayerTap: () -> Void`.
- Produces: a non-cancelling AVKit tap callback, player-session begin/end calls, the upper-right overlay, and manual regression instructions.

- [ ] **Step 1: Add a failing representable test for the non-cancelling tap callback**

Add `ios/PatataTube/Tests/PlayerViewControllerTests.swift`:

```swift
import AVFoundation
import SwiftUI
import Testing
import UIKit
import ViewInspector
@testable import PatataTube

@Suite("Player view controller bridge")
@MainActor
struct PlayerViewControllerTests {
    @Test func installsOneNonCancellingTapRecognizer() {
        let sut = PlayerViewController(
            player: AVPlayer(),
            attached: true,
            resumeAfterDetaching: false,
            onPlayerTap: {}
        )
        let coordinator = sut.makeCoordinator()
        let recognizer = coordinator.makeTapRecognizer()
        #expect(recognizer.cancelsTouchesInView == false)
        #expect(recognizer.delegate === coordinator)
    }

    @Test func normalAndSleepPlayersBothContainTheOrientationOverlay() throws {
        let model = AppModel()
        for sleepMode in [false, true] {
            let sut = VideoPlayerView(
                videos: [], startIndex: 0, sleepMode: sleepMode
            )
            .environmentObject(model)
            #expect(try sut.inspect().find(OrientationLockOverlay.self) != nil)
        }
    }
}
```

- [ ] **Step 2: Run the bridge suite and verify it fails**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/PlayerViewControllerTests
```

Expected: compile failure because `onPlayerTap` and `makeCoordinator()` are absent.

- [ ] **Step 3: Add a simultaneous, non-cancelling tap observer to AVKit**

Extend `PlayerViewController` with `let onPlayerTap: () -> Void`, implement `makeCoordinator()`, and add this coordinator:

```swift
final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onPlayerTap: () -> Void

    init(onPlayerTap: @escaping () -> Void) {
        self.onPlayerTap = onPlayerTap
    }

    @objc func tapped() { onPlayerTap() }

    func makeTapRecognizer() -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}
```

In `makeUIViewController`, attach `context.coordinator.makeTapRecognizer()` to `controller.view`. In `updateUIViewController`, update `context.coordinator.onPlayerTap = onPlayerTap` so the callback never becomes stale. Preserve all existing attach/detach and playback behavior.

- [ ] **Step 4: Integrate coordinator state and overlay into the player**

In `VideoPlayerView`, add:

```swift
@StateObject private var orientationLock = OrientationLockCoordinator.shared
@StateObject private var orientationControlVisibility = OrientationControlVisibility()

private var activeWindowScene: UIWindowScene? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
}
```

Pass this callback to `PlayerViewController`:

```swift
onPlayerTap: { orientationControlVisibility.reveal() }
```

Place this overlay after the player and before the sleep overlay so sleep mode retains topmost input blocking:

```swift
OrientationLockOverlay(
    isLocked: orientationLock.isLocked,
    isVisible: orientationControlVisibility.isVisible,
    isBlocked: showingSleepOverlay,
    onToggle: {
        orientationLock.toggle(in: activeWindowScene)
        orientationControlVisibility.reveal()
    }
)
```

At the beginning of the existing `.task`, call `orientationLock.beginPlayerSession(in: activeWindowScene)` before `await setup()`. When `showingSleepOverlay` becomes true, call `orientationControlVisibility.hide()`. In `.onDisappear`, call both `orientationControlVisibility.hide()` and `orientationLock.endPlayerSession(in: activeWindowScene)` before teardown completes. Do not reset either object in `advance(by:)`; this preserves the lock across autoplay.

- [ ] **Step 5: Run focused and full iOS tests**

Run from `ios/PatataTube`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/PlayerViewControllerTests
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: the bridge test, both-playback-mode overlay test, and the complete `PatataTubeTests` suite pass with zero failures.

- [ ] **Step 6: Add the manual orientation-lock checklist**

Append this section to `ios/README.md`:

```markdown
### Player orientation lock

1. Start a normal video in portrait, tap the video, and confirm the upper-right unlocked-rotation button appears with the AVKit controls and hides after about four seconds.
2. Reveal the controls, enable the lock, rotate through both landscape directions, and confirm the player remains portrait.
3. Disable the lock while physically landscape and confirm the player immediately rotates to that landscape direction.
4. Repeat from landscape, including portrait upside down on iPad; confirm iPhone never enters portrait upside down.
5. Enable the lock with autoplay on and let the next video start; confirm the lock remains enabled.
6. Dismiss and open another video; confirm the lock starts disabled and normal rotation works.
7. Repeat in play-and-sleep playback; after the black completion overlay appears, confirm the orientation button cannot be revealed or tapped.
8. Enable Control Center Rotation Lock and confirm PatataTube's button reports only its own state; unlocking PatataTube does not disable the system setting.
9. Confirm scrubbing, native playback controls, pull-down dismissal, subtitles/audio selection, and AirPlay still work.
```

- [ ] **Step 7: Build and inspect the scoped diff**

Run from the repository root:

```bash
rtk xcodebuild build -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
rtk git diff --check
rtk git diff -- ios/PatataTube/Sources ios/PatataTube/Tests ios/README.md
```

Expected: build succeeds, `git diff --check` emits no errors, and the diff contains only orientation-lock work plus the manual checklist.

- [ ] **Step 8: Commit the integration**

```bash
rtk git add ios/PatataTube/Sources/PlayerViewController.swift ios/PatataTube/Sources/VideoPlayerView.swift ios/PatataTube/Tests/PlayerViewControllerTests.swift ios/README.md
rtk git commit -m "feat(ios): lock player orientation on demand"
```

---

### Task 4: Final regression verification

**Files:**
- Verify only; no planned source changes.

**Interfaces:**
- Consumes: all artifacts from Tasks 1–3.
- Produces: evidence that the completed feature builds, passes tests, and leaves unrelated user changes untouched.

- [ ] **Step 1: Run the full relevant verification set**

Run from the repository root:

```bash
rtk xcodebuild test -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
rtk xcodebuild build -project ios/PatataTube/PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.3.1'
rtk git diff --check
rtk git status --short
```

Expected: all tests pass, both iPhone test build and iPad build succeed, whitespace validation passes, and pre-existing `plex.py` / `tests/test_plex.py` modifications remain unstaged and unmodified by this work.

- [ ] **Step 2: Review commits and requirement coverage**

```bash
rtk git log -4 --oneline
rtk git show --stat --oneline HEAD~2..HEAD
```

Expected: three focused feature commits cover the coordinator, overlay, and player integration; no unrelated files appear.
