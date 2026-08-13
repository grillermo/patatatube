# Horizontal Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the video player's "lock current orientation" control with a "force horizontal" control: toggling it on rotates the video to landscape and keeps it there regardless of how the phone is physically held, until toggled off.

**Architecture:** The existing three-layer design is kept — a pure-value state struct (`HorizontalLockState`), a `@MainActor` `ObservableObject` coordinator that owns the scene/registry/device-notification plumbing, and a SwiftUI overlay. Only the *lock target* changes: instead of capturing the scene's current interface orientation, locking narrows the supported mask to the landscape subset of the normal mask and requests the last landscape the device was actually seen in (falling back to `.landscapeRight`). Everything is renamed from `OrientationLock*` to `HorizontalLock*`.

**Tech Stack:** Swift 6, SwiftUI, UIKit (`UIWindowScene.requestGeometryUpdate`), swift-testing (`@Suite`/`@Test`/`#expect`), ViewInspector, swift-clocks (`TestClock`), XcodeGen.

**Spec:** No separate spec document — this is a bounded change; the approved design is reproduced in "Design Decisions" below.

## Global Constraints

- **Never run the iOS tests unless the user explicitly asks.** Neither `swift test` nor `xcodebuild ... test`. Steps below that say "run the tests" mean *when the user asks*; otherwise state which tests would cover the change and move on. (`CLAUDE.md`)
- All touched code lives in `ios/PatataTube/Sources/` and `ios/PatataTube/Tests/`, the `PatataTube` app target — **not** the `PatataTubeKit` SwiftPM package. It builds only through `xcodebuild`, so `swift build`/`swift test` will not catch a break here.
- `ios/PatataTube/project.yml` lists `- Sources` as a glob, so renaming source files needs `xcodegen generate`, never a hand edit of `project.pbxproj`.
- Build command (safe to run, does not run tests):
  `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build`
- Test command (**only when the user asks**), whole target — `-only-testing:` hangs:
  `cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" test`
- Do not add new ViewInspector tests that inspect a large SwiftUI view (it segfaults the test process). `HorizontalLockOverlay` is small and safe.

## Design Decisions (approved)

1. **Lock target:** both landscapes stay allowed (`[.landscapeLeft, .landscapeRight]`); the requested orientation is the last landscape the device was seen in, else `.landscapeRight`. Flipping the phone 180° while locked still rotates the video; portrait never does.
2. **Lifetime:** the whole player session. Survives auto-advance to the next video, cleared on dismiss. This is the existing lifetime — no new persistence.
3. **Rename:** full — types, files, and tests.
4. **Icons:** `rectangle.landscape.rotate` when off, `lock.rotation` when on; labels "Force horizontal video" / "Stop forcing horizontal video".

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `ios/PatataTube/Sources/HorizontalLockCoordinator.swift` | `HorizontalLockState`, `HorizontalLockScene`, `DeviceOrientationNotifications`, `HorizontalLockRegistry`, `HorizontalLockCoordinator` | `git mv` from `OrientationLockCoordinator.swift`, renamed + new lock semantics |
| `ios/PatataTube/Sources/HorizontalLockOverlay.swift` | `OrientationControlVisibility` (unchanged name — it also governs the sleep button), `HorizontalLockOverlay` | `git mv` from `OrientationLockOverlay.swift`, renamed + new icons/labels |
| `ios/PatataTube/Sources/VideoPlayerView.swift` | Player screen; owns the coordinator | Property/type renames only |
| `ios/PatataTube/Sources/PlayerViewController.swift` | Surfaces the `UIWindowScene` to the coordinator | Protocol name renames only |
| `ios/PatataTube/Sources/PatataTubeApp.swift` | `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` | Registry/coordinator name renames only |
| `ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift` | State + scene/registry tests | `git mv`, renamed, lock-target tests rewritten |
| `ios/PatataTube/Tests/HorizontalLockOverlayTests.swift` | Overlay + visibility tests | `git mv`, renamed, icon/label tests rewritten |
| `ios/PatataTube/Tests/PlayerViewControllerTests.swift` | Player VC tests | Protocol name renames only |

---

### Task 1: Mechanical rename, no behavior change

Pure rename so the semantic change in Task 2 lands as a readable diff. After this task the app behaves exactly as it does today.

**Files:**
- Rename: `ios/PatataTube/Sources/OrientationLockCoordinator.swift` → `ios/PatataTube/Sources/HorizontalLockCoordinator.swift`
- Rename: `ios/PatataTube/Sources/OrientationLockOverlay.swift` → `ios/PatataTube/Sources/HorizontalLockOverlay.swift`
- Rename: `ios/PatataTube/Tests/OrientationLockCoordinatorTests.swift` → `ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift`
- Rename: `ios/PatataTube/Tests/OrientationLockOverlayTests.swift` → `ios/PatataTube/Tests/HorizontalLockOverlayTests.swift`
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`, `ios/PatataTube/Sources/PlayerViewController.swift`, `ios/PatataTube/Sources/PatataTubeApp.swift`, `ios/PatataTube/Tests/PlayerViewControllerTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the renamed symbols every later task uses —
  - `struct HorizontalLockState` with `init(normalMask: UIInterfaceOrientationMask)`, `let normalMask`, `private(set) var supportedMask`, `private(set) var lockedOrientation: UIInterfaceOrientation?`, `private(set) var latestRequestedInterfaceOrientation: UIInterfaceOrientation?`, `var isHorizontal: Bool`, `mutating func record(deviceOrientation: UIDeviceOrientation)`, `@discardableResult mutating func lock(to: UIInterfaceOrientation) -> Bool` (signature changes in Task 2), `mutating func unlock() -> UIInterfaceOrientation?`, `mutating func reset()`
  - `protocol HorizontalLockScene: AnyObject` with `var horizontalLockIdentifier: ObjectIdentifier { get }`, `var interfaceOrientationForLock: UIInterfaceOrientation { get }`, `func applySupportedOrientations(_ supportedOrientations: UIInterfaceOrientationMask, requestedOrientation: UIInterfaceOrientation?)`
  - `final class HorizontalLockRegistry` with `static let shared`, `register(owner:scene:supportedOrientations:) -> Bool`, `update(owner:scene:supportedOrientations:) -> Bool`, `unregister(owner:scene:)`, `unregister(owner:sceneIdentifier:)`, `supportedOrientations(for:default:) -> UIInterfaceOrientationMask`
  - `final class HorizontalLockCoordinator: ObservableObject` with `@Published private(set) var isHorizontal: Bool`, `static var normalMask`, `init(normalMask:registry:deviceOrientationNotifications:notificationCenter:)`, `beginPlayerSession(in: any HorizontalLockScene)`, `toggle()`, `endPlayerSession()`, `var supportedOrientations: UIInterfaceOrientationMask`
  - `struct HorizontalLockOverlay: View` with `static let verticalOffsetFraction: CGFloat`, and members `isHorizontal: Bool`, `isVisible: Bool`, `isBlocked: Bool`, `onToggle: () -> Void`, `isSleepOn: Bool`, `onToggleSleep: () -> Void`
  - `final class OrientationControlVisibility: ObservableObject` — **name unchanged**

- [ ] **Step 1: Rename the four files with git so history follows**

```bash
cd ios/PatataTube
git mv Sources/OrientationLockCoordinator.swift Sources/HorizontalLockCoordinator.swift
git mv Sources/OrientationLockOverlay.swift Sources/HorizontalLockOverlay.swift
git mv Tests/OrientationLockCoordinatorTests.swift Tests/HorizontalLockCoordinatorTests.swift
git mv Tests/OrientationLockOverlayTests.swift Tests/HorizontalLockOverlayTests.swift
```

- [ ] **Step 2: Rewrite the symbol names across sources and tests**

Apply these substitutions to every `.swift` file under `ios/PatataTube/Sources` and `ios/PatataTube/Tests`. Order matters — the longest identifiers first, so a shorter prefix never eats a longer name.

```bash
cd ios/PatataTube
FILES=$(git ls-files 'Sources/*.swift' 'Tests/*.swift')
for f in $FILES; do
  perl -pi -e '
    s/\bOrientationLockCoordinatorTests\b/HorizontalLockCoordinatorTests/g;
    s/\bOrientationLockOverlayTests\b/HorizontalLockOverlayTests/g;
    s/\bOrientationLockSceneTests\b/HorizontalLockSceneTests/g;
    s/\bOrientationLockTestScene\b/HorizontalLockTestScene/g;
    s/\bOrientationLockCoordinator\b/HorizontalLockCoordinator/g;
    s/\bOrientationLockRegistry\b/HorizontalLockRegistry/g;
    s/\bOrientationLockOverlay\b/HorizontalLockOverlay/g;
    s/\bOrientationLockScene\b/HorizontalLockScene/g;
    s/\bOrientationLockState\b/HorizontalLockState/g;
    s/\borientationLockIdentifier\b/horizontalLockIdentifier/g;
    s/\bapplyOrientationLock\(\s*supportedOrientations:/applySupportedOrientations(/g;
    s/\bfunc applyOrientationLock\(\s*\n?\s*supportedOrientations:/func applySupportedOrientations(/g;
    s/\bapplyOrientationLock\b/applySupportedOrientations/g;
  ' "$f"
done
```

`applyOrientationLock` is declared and called with the first argument on its own line in both `HorizontalLockCoordinator.swift` and the test scene, so the `perl -pi` line-at-a-time pass will not collapse the label. **After running the script, hand-fix every remaining `applySupportedOrientations(` call and declaration** so the first parameter is unlabeled:

```swift
// protocol declaration and UIWindowScene conformance
func applySupportedOrientations(
    _ supportedOrientations: UIInterfaceOrientationMask,
    requestedOrientation: UIInterfaceOrientation?
)

// call sites in HorizontalLockCoordinator
scene.applySupportedOrientations(state.supportedMask, requestedOrientation: nil)
activeScene.applySupportedOrientations(state.supportedMask, requestedOrientation: requestedOrientation)
activeScene.applySupportedOrientations(state.supportedMask, requestedOrientation: pending)
```

- [ ] **Step 3: Rename `isLocked` to `isHorizontal` on the state and coordinator**

In `Sources/HorizontalLockCoordinator.swift`:

```swift
struct HorizontalLockState {
    // ...
    var isHorizontal: Bool { lockedOrientation != nil }
```

```swift
final class HorizontalLockCoordinator: ObservableObject {
    @Published private(set) var isHorizontal = false
```

and inside `toggle()` / `beginPlayerSession()` / `endPlayerSession()` replace every `isLocked = ` with `isHorizontal = ` and `state.isLocked` with `state.isHorizontal`.

In `Sources/HorizontalLockOverlay.swift` rename the member and its uses:

```swift
struct HorizontalLockOverlay: View {
    static let verticalOffsetFraction: CGFloat = 0.20

    let isHorizontal: Bool
    let isVisible: Bool
    let isBlocked: Bool
    let onToggle: () -> Void
    let isSleepOn: Bool
    let onToggleSleep: () -> Void
```

```swift
controlIcon(isHorizontal ? "lock.rotation" : "rotate.right", active: isHorizontal)
```
```swift
.accessibilityLabel(isHorizontal ? "Unlock video orientation" : "Lock video orientation")
```

In `Sources/VideoPlayerView.swift`:

```swift
    @StateObject private var horizontalLock: HorizontalLockCoordinator
```
```swift
        _horizontalLock = StateObject(wrappedValue: HorizontalLockCoordinator())
```
```swift
                    onSceneAvailable: { horizontalLock.beginPlayerSession(in: $0) }
```
```swift
            HorizontalLockOverlay(
                isHorizontal: horizontalLock.isHorizontal,
                isVisible: orientationControlVisibility.isVisible,
                isBlocked: false,
                onToggle: {
                    horizontalLock.toggle()
                    orientationControlVisibility.reveal()
                },
```
```swift
            horizontalLock.endPlayerSession()
```

In `Tests/HorizontalLockCoordinatorTests.swift` and `Tests/HorizontalLockOverlayTests.swift`, replace `sut.isLocked` → `sut.isHorizontal`, `first.isLocked` → `first.isHorizontal`, `second.isLocked` → `second.isHorizontal`, and the overlay's `isLocked:` argument label → `isHorizontal:`.

- [ ] **Step 4: Regenerate the Xcode project**

```bash
cd ios/PatataTube && xcodegen generate
```

- [ ] **Step 5: Build to verify the rename compiles**

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" build
```
Expected: `** BUILD SUCCEEDED **`. Any `cannot find 'OrientationLock…' in scope` means a call site the substitution missed — fix and rebuild.

- [ ] **Step 6: Grep for stragglers**

```bash
cd ios/PatataTube && grep -rn "OrientationLock\|orientationLock\|isLocked" Sources Tests
```
Expected: no output. (`orientationControlVisibility` and `OrientationControlVisibility` keep their names and contain no `OrientationLock` substring, so they will not appear.)

- [ ] **Step 7: Commit**

```bash
git add -A ios/PatataTube
git commit -m "refactor(ios): rename OrientationLock* to HorizontalLock*"
```

---

### Task 2: `HorizontalLockState` locks to landscape, not to the current orientation

**Files:**
- Modify: `ios/PatataTube/Sources/HorizontalLockCoordinator.swift` (the `HorizontalLockState` struct)
- Test: `ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift` (the `HorizontalLockCoordinatorTests` suite)

**Interfaces:**
- Consumes: `HorizontalLockState` as renamed in Task 1.
- Produces, replacing `lock(to:)`:
  - `var landscapeMask: UIInterfaceOrientationMask` — `normalMask.intersection([.landscapeLeft, .landscapeRight])`
  - `private(set) var latestLandscapeInterfaceOrientation: UIInterfaceOrientation?`
  - `mutating func record(interfaceOrientation: UIInterfaceOrientation)` — the seed path used by the coordinator
  - `@discardableResult mutating func lock() -> UIInterfaceOrientation?` — sets `supportedMask` to `landscapeMask`, sets `lockedOrientation`, and returns the orientation to request; returns `nil` and changes nothing when `landscapeMask` is empty
  - `unlock()`, `reset()`, `record(deviceOrientation:)`, `isHorizontal` keep their Task-1 signatures. `reset()` additionally clears `latestLandscapeInterfaceOrientation`.

- [ ] **Step 1: Write the failing tests**

In `Tests/HorizontalLockCoordinatorTests.swift`, **delete** these four now-obsolete tests from the `HorizontalLockCoordinatorTests` suite: `lockCapturesTheDisplayedInterfaceOrientation`, `invalidInterfaceOrientationCannotLock`, `rotationWhileLockedIsRememberedWithoutChangingTheMask`, and `unlockRestoresNormalMaskAndReturnsLatestSupportedOrientation`. In `resetClearsLockAndPendingRotation`, change `_ = sut.lock(to: .landscapeRight)` to `_ = sut.lock()`. Then add:

```swift
    @Test func lockingWithoutAnySeenLandscapeDefaultsToLandscapeRight() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .portrait)
        let requested = sut.lock()
        #expect(requested == .landscapeRight)
        #expect(sut.isHorizontal)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
    }

    @Test func lockingFromPortraitRequestsTheLastSeenLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)   // interface .landscapeLeft
        sut.record(deviceOrientation: .portrait)
        #expect(sut.lock() == .landscapeLeft)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
    }

    @Test func seededInterfaceOrientationCountsAsASeenLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(interfaceOrientation: .landscapeRight)
        #expect(sut.lock() == .landscapeRight)
    }

    @Test func bothLandscapesStaySupportedSoAOneEightyFlipStillRotates() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock()
        sut.record(deviceOrientation: .landscapeLeft)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
        #expect(sut.isHorizontal)
    }

    @Test func portraitRotationsWhileLockedAreStillRecordedForTheUnlockRestore() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock()
        sut.record(deviceOrientation: .portrait)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
        #expect(sut.unlock() == .portrait)
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func aPortraitOnlyMaskCannotGoHorizontal() {
        var sut = HorizontalLockState(normalMask: .portrait)
        #expect(sut.lock() == nil)
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == .portrait)
    }

    @Test func resetClearsTheRememberedLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)
        sut.reset()
        #expect(sut.lock() == .landscapeRight)   // back to the default, not .landscapeLeft
    }
```

- [ ] **Step 2: Run the tests to verify they fail (only if the user has asked for a test run)**

```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination "platform=iOS Simulator,id=$(xcrun simctl list devices available | grep -m1 -o '[0-9A-F-]\{36\}')" test
```
Expected: compile failure — `extra argument`/`cannot find` for `lock()` and `record(interfaceOrientation:)`. If the user has not asked, skip this step and say so.

- [ ] **Step 3: Implement the new state**

Replace the body of `HorizontalLockState` in `Sources/HorizontalLockCoordinator.swift` with:

```swift
struct HorizontalLockState {
    let normalMask: UIInterfaceOrientationMask
    private(set) var supportedMask: UIInterfaceOrientationMask
    private(set) var lockedOrientation: UIInterfaceOrientation?
    private(set) var latestRequestedInterfaceOrientation: UIInterfaceOrientation?
    /// Last landscape the device was actually seen in. This is the target a
    /// lock requests, so toggling on from portrait rotates the way the viewer
    /// last held the phone rather than always the same way.
    private(set) var latestLandscapeInterfaceOrientation: UIInterfaceOrientation?

    var isHorizontal: Bool { lockedOrientation != nil }

    /// The landscape orientations this device is willing to display. Both stay
    /// supported while locked, so a 180° flip still rotates the video — only
    /// portrait is taken away.
    var landscapeMask: UIInterfaceOrientationMask {
        normalMask.intersection([.landscapeLeft, .landscapeRight])
    }

    init(normalMask: UIInterfaceOrientationMask) {
        self.normalMask = normalMask
        self.supportedMask = normalMask
    }

    mutating func record(deviceOrientation: UIDeviceOrientation) {
        guard let interfaceOrientation = deviceOrientation.interfaceOrientation else { return }
        record(interfaceOrientation: interfaceOrientation)
    }

    /// Recorded even while locked: `latestRequestedInterfaceOrientation` is what
    /// unlocking restores, so a portrait phone must still be observed.
    mutating func record(interfaceOrientation: UIInterfaceOrientation) {
        guard normalMask.contains(interfaceOrientation.mask) else { return }
        latestRequestedInterfaceOrientation = interfaceOrientation
        if landscapeMask.contains(interfaceOrientation.mask) {
            latestLandscapeInterfaceOrientation = interfaceOrientation
        }
    }

    /// Narrow to landscape and report the orientation to rotate to, or nil when
    /// this device supports no landscape at all (nothing changes in that case).
    @discardableResult
    mutating func lock() -> UIInterfaceOrientation? {
        let mask = landscapeMask
        guard !mask.isEmpty else { return nil }
        let target = latestLandscapeInterfaceOrientation
            ?? (mask.contains(.landscapeRight) ? .landscapeRight : .landscapeLeft)
        lockedOrientation = target
        supportedMask = mask
        return target
    }

    mutating func unlock() -> UIInterfaceOrientation? {
        lockedOrientation = nil
        supportedMask = normalMask
        return latestRequestedInterfaceOrientation
    }

    mutating func reset() {
        lockedOrientation = nil
        latestRequestedInterfaceOrientation = nil
        latestLandscapeInterfaceOrientation = nil
        supportedMask = normalMask
    }
}
```

Leave the two `private extension`s (`UIDeviceOrientation.interfaceOrientation`, `UIInterfaceOrientation.mask`) below it exactly as they are.

- [ ] **Step 4: Fix the one call site this breaks**

`HorizontalLockCoordinator.toggle()` still calls `state.lock(to:)`. Task 3 rewrites it properly; for now make it compile:

```swift
            guard let target = state.lock() else { return }
            isHorizontal = true
            requestedOrientation = target
```
and delete the now-unused `let interfaceOrientation = activeScene.interfaceOrientationForLock` line above it.

- [ ] **Step 5: Build, then run the tests only if the user has asked**

Build: as in Global Constraints. Expected `** BUILD SUCCEEDED **`.
Tests (on request only): all seven new tests PASS; the `HorizontalLockSceneTests` suite may still fail — Task 3 fixes it.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/HorizontalLockCoordinator.swift ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift
git commit -m "feat(ios): lock to landscape instead of the current orientation"
```

---

### Task 3: Coordinator seeds the landscape memory and applies the landscape mask

**Files:**
- Modify: `ios/PatataTube/Sources/HorizontalLockCoordinator.swift` (`HorizontalLockCoordinator.beginPlayerSession`, `toggle`)
- Test: `ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift` (the `HorizontalLockSceneTests` suite)

**Interfaces:**
- Consumes: `HorizontalLockState.lock() -> UIInterfaceOrientation?`, `record(interfaceOrientation:)`, `landscapeMask` (Task 2); `HorizontalLockScene.interfaceOrientationForLock`, `applySupportedOrientations(_:requestedOrientation:)` (Task 1).
- Produces: no signature changes. `toggle()` now always yields `supportedMask == [.landscapeLeft, .landscapeRight]` on a phone.

- [ ] **Step 1: Write the failing tests**

In `Tests/HorizontalLockCoordinatorTests.swift`, update the `HorizontalLockSceneTests` suite. Replace `simultaneousPlayerSessionsKeepSceneMasksAndObservationIndependent` and `sceneHandoffUnlocksOnlyTheOldSceneAndThenTargetsTheExactNewScene` with these, and add the third:

```swift
    private let landscapeMask: UIInterfaceOrientationMask = [.landscapeLeft, .landscapeRight]

    @Test func simultaneousPlayerSessionsKeepSceneMasksAndObservationIndependent() {
        let registry = HorizontalLockRegistry()
        let firstDevice = DeviceOrientationNotificationsSpy()
        let secondDevice = DeviceOrientationNotificationsSpy()
        let first = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: firstDevice,
            notificationCenter: NotificationCenter()
        )
        let second = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: secondDevice,
            notificationCenter: NotificationCenter()
        )
        let portraitScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let landscapeScene = HorizontalLockTestScene(interfaceOrientation: .landscapeRight)

        first.beginPlayerSession(in: portraitScene)
        first.toggle()
        second.beginPlayerSession(in: landscapeScene)
        second.toggle()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == landscapeMask)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == landscapeMask)
        #expect(first.isHorizontal)
        #expect(second.isHorizontal)

        first.endPlayerSession()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == landscapeMask)
        #expect(!first.isHorizontal)
        #expect(second.isHorizontal)
        #expect(firstDevice.endCount == 1)
        #expect(secondDevice.endCount == 0)
    }

    /// A portrait phone has no seen landscape, so it takes the default; a scene
    /// that is already landscape seeds the memory and keeps that side.
    @Test func lockTargetComesFromTheSceneWhenTheDeviceHasNeverBeenLandscape() {
        let registry = HorizontalLockRegistry()
        let portraitCoordinator = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(orientation: .portrait),
            notificationCenter: NotificationCenter()
        )
        let landscapeCoordinator = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(orientation: .faceUp),
            notificationCenter: NotificationCenter()
        )
        let portraitScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let landscapeScene = HorizontalLockTestScene(interfaceOrientation: .landscapeLeft)

        portraitCoordinator.beginPlayerSession(in: portraitScene)
        portraitCoordinator.toggle()
        landscapeCoordinator.beginPlayerSession(in: landscapeScene)
        landscapeCoordinator.toggle()

        #expect(portraitScene.applications.last?.1 == .landscapeRight)
        #expect(landscapeScene.applications.last?.1 == .landscapeLeft)
    }

    @Test func sceneHandoffUnlocksOnlyTheOldSceneAndThenTargetsTheExactNewScene() {
        let registry = HorizontalLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let sut = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        let firstScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let secondScene = HorizontalLockTestScene(interfaceOrientation: .landscapeLeft)

        sut.beginPlayerSession(in: firstScene)
        sut.toggle()
        sut.beginPlayerSession(in: secondScene)
        sut.toggle()

        #expect(registry.supportedOrientations(for: firstScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: secondScene, default: phoneMask) == landscapeMask)
        #expect(firstScene.applications.count == 2)
        #expect(firstScene.applications.last?.0 == phoneMask)
        #expect(secondScene.applications.count == 1)
        #expect(secondScene.applications.last?.0 == landscapeMask)
        #expect(secondScene.applications.last?.1 == .landscapeLeft)
        #expect(device.beginCount == 2)
        #expect(device.endCount == 1)
    }
```

Also update `replacingALockedOwnerInTheSameSceneAppliesTheNewNormalMaskOnce` — it asserts only `phoneMask` values, so it needs no change; and `endingAfterTheSceneDisappearsStillResetsAndUnregistersTheSession`, which asserts `sut.supportedOrientations == phoneMask` after ending — also unchanged. `staleOwnerCannotUnregisterTheCurrentSceneSession` and `appDelegateUsesTheSceneBelongingToTheSuppliedWindow` exercise the registry directly and need no change beyond the Task-1 rename.

- [ ] **Step 2: Run the tests to verify they fail (only if the user has asked)**

Expected: `simultaneousPlayerSessionsKeepSceneMasksAndObservationIndependent` and `lockTargetComesFromTheSceneWhenTheDeviceHasNeverBeenLandscape` FAIL — the portrait scene's application reports `.portrait`, not the landscape mask, because `beginPlayerSession` never seeds the landscape memory.

- [ ] **Step 3: Seed the landscape memory from the scene**

In `HorizontalLockCoordinator.beginPlayerSession(in:)`, insert the seed immediately after `state.reset()` and before `beginObservation()` at the end — so a live device reading, which arrives inside `beginObservation`, overrides the seed:

```swift
    func beginPlayerSession(in scene: any HorizontalLockScene) {
        if activeScene?.horizontalLockIdentifier == scene.horizontalLockIdentifier { return }
        if activeSceneIdentifier != nil { endPlayerSession() }
        state.reset()
        isHorizontal = false
        // The player can open while the device reports .faceUp/.unknown, which
        // no device notification will ever resolve into a side. The scene's own
        // interface orientation is the only landscape evidence in that case.
        state.record(interfaceOrientation: scene.interfaceOrientationForLock)
        activeScene = scene
        activeSceneIdentifier = scene.horizontalLockIdentifier
        let replacedOwner = registry.register(
            owner: self,
            scene: scene,
            supportedOrientations: state.supportedMask
        )
        if replacedOwner {
            scene.applySupportedOrientations(state.supportedMask, requestedOrientation: nil)
        }
        beginObservation()
    }
```

- [ ] **Step 4: Confirm `toggle()` reads as intended**

After Task 2 Step 4 it should already be:

```swift
    func toggle() {
        guard let activeScene else { return }
        let requestedOrientation: UIInterfaceOrientation?
        if state.isHorizontal {
            requestedOrientation = state.unlock()
            isHorizontal = false
        } else {
            guard let target = state.lock() else { return }
            isHorizontal = true
            requestedOrientation = target
        }
        guard registry.update(
            owner: self,
            scene: activeScene,
            supportedOrientations: state.supportedMask
        ) else { return }
        activeScene.applySupportedOrientations(
            state.supportedMask,
            requestedOrientation: requestedOrientation
        )
    }
```

- [ ] **Step 5: Build; run the tests only if the user has asked**

Expected on a test run: the whole `HorizontalLockCoordinatorTests` and `HorizontalLockSceneTests` suites PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/HorizontalLockCoordinator.swift ios/PatataTube/Tests/HorizontalLockCoordinatorTests.swift
git commit -m "feat(ios): seed the horizontal lock target from the player scene"
```

---

### Task 4: Overlay icon and labels say "horizontal", not "lock orientation"

**Files:**
- Modify: `ios/PatataTube/Sources/HorizontalLockOverlay.swift`
- Test: `ios/PatataTube/Tests/HorizontalLockOverlayTests.swift`

**Interfaces:**
- Consumes: `HorizontalLockOverlay` with member `isHorizontal` (Task 1).
- Produces: accessibility labels `"Force horizontal video"` (off) and `"Stop forcing horizontal video"` (on); SF Symbols `rectangle.landscape.rotate` (off) and `lock.rotation` (on). No API change.

- [ ] **Step 1: Write the failing test**

In `Tests/HorizontalLockOverlayTests.swift`, replace `unlockedAndLockedStatesUseAccessibleSystemSymbols` with:

```swift
    @Test func horizontalOffAndOnStatesUseAccessibleSystemSymbols() throws {
        var toggles = 0
        let off = HorizontalLockOverlay(
            isHorizontal: false, isVisible: true, isBlocked: false,
            onToggle: { toggles += 1 }, isSleepOn: false, onToggleSleep: {}
        )
        let offButton = try off.inspect().find(
            ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Force horizontal video" }
        )
        #expect(try offButton.find(ViewType.Image.self).actualImage().name() == "rectangle.landscape.rotate")
        try offButton.tap()
        #expect(toggles == 1)

        let on = HorizontalLockOverlay(
            isHorizontal: true, isVisible: true, isBlocked: false,
            onToggle: {}, isSleepOn: false, onToggleSleep: {}
        )
        let onButton = try on.inspect().find(
            ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Stop forcing horizontal video" }
        )
        #expect(try onButton.find(ViewType.Image.self).actualImage().name() == "lock.rotation")
    }
```

The remaining tests in the suite (`buttonIsPositionedTwentyPercentDownThePlayer`, `sleepButtonTogglesAndTintsWhenOn`, `blockedOverlayContainsNoButton`, `hiddenOverlayContainsNoButton`, `visibilityAutoHidesAfterFourSeconds`, `revealingAgainRefreshesTheTimeout`) already compile against the Task-1 rename and need no further change.

- [ ] **Step 2: Run the test to verify it fails (only if the user has asked)**

Expected: FAIL — `find` throws `InspectionError`, no button carries the label "Force horizontal video".

- [ ] **Step 3: Implement**

In `Sources/HorizontalLockOverlay.swift`, inside the first `Button`'s label and modifier:

```swift
                        Button {
                            onToggle()
                        } label: {
                            controlIcon(isHorizontal ? "lock.rotation" : "rectangle.landscape.rotate",
                                        active: isHorizontal)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isHorizontal ? "Stop forcing horizontal video" : "Force horizontal video")
```

- [ ] **Step 4: Build; run the tests only if the user has asked**

Expected on a test run: the whole `HorizontalLockOverlay` suite PASSES.

- [ ] **Step 5: Manual check on the simulator (the part no test covers)**

`requestGeometryUpdate` does nothing in a unit test, so the actual rotation needs eyes on it. Run the app, open a video, and confirm:
1. Phone held portrait, tap the control → the video rotates to landscape and the icon turns accent-coloured.
2. Rotate the phone back to portrait → the video **stays** landscape.
3. Flip the phone 180° between the two landscapes → the video follows.
4. Let the video auto-advance to the next one → still landscape.
5. Tap the control again while holding the phone portrait → the video returns to portrait.
6. Pull down to dismiss the player → the grid is usable in portrait again.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/HorizontalLockOverlay.swift ios/PatataTube/Tests/HorizontalLockOverlayTests.swift
git commit -m "feat(ios): relabel the player control as force-horizontal"
```

---

## Notes for the reviewer

- `OrientationControlVisibility` deliberately keeps its name: it governs the sleep button as well as the horizontal-lock button, so "orientation" would be the wrong narrowing.
- The `isBlocked: false` argument at the `HorizontalLockOverlay` call site in `VideoPlayerView` is pre-existing dead weight (always false). Out of scope; leave it.
- `HorizontalLockCoordinator.normalMask` returns `.all` on iPad, so `landscapeMask` there is still `[.landscapeLeft, .landscapeRight]` — upside-down portrait is excluded from the lock target, which is correct.
