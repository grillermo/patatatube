# Autoplay Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an autoplay switch to the `EpisodesView` and `VideoGridView` toolbars; when on, a finished video automatically starts the next video in the same queue.

**Architecture:** A session-only `@Published var autoplay` on `AppModel` (already an `@EnvironmentObject` in every view involved) holds the shared state. The end-of-item decision moves out of `VideoPlayerView` into a pure `playbackEndAction(autoplay:isForeground:)` function in `PatataTubeKit` so its four-way truth table is testable without a player. A shared `AutoplayToggle` view takes a `Binding<Bool>`; both toolbars pass `$model.autoplay`.

**Tech Stack:** Swift 6, SwiftUI, AVKit, XCTest (PatataTubeKit), swift-testing + ViewInspector (app target), XcodeGen, librsvg (`rsvg-convert`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-20-autoplay-toggle-design.md`.
- Swift tools 6.0; iOS deployment target 17.0; `SWIFT_VERSION: "6.0"`.
- `PatataTubeKit` tests use **XCTest** (`final class ...: XCTestCase`, `XCTAssertEqual`). App-target tests use **swift-testing** (`@Suite`, `@Test`, `#expect`) plus ViewInspector. Do not mix the two conventions.
- Autoplay state is **session-only** — never add `@AppStorage`/`UserDefaults` persistence for it.
- `project.yml` globs whole directories (`sources: - Sources`, `- Tests`), so new files need **no** `project.yml` edit — but they do need `xcodegen generate`.
- `rsvg-convert` lives at `/opt/homebrew/bin/rsvg-convert` (librsvg 2.62.3); prefix commands with `export PATH="/opt/homebrew/bin:$PATH"` if it is not on PATH.
- Kit tests run from `ios/PatataTubeKit` with `swift test`. App tests run from `ios/PatataTube` with:
  `xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'`
- **Deviations from the spec, intentional — two, both for testability:**
  1. The spec sketched `AutoplayToggle` reading `@EnvironmentObject var model: AppModel`. This plan gives it a `@Binding var isOn: Bool` instead. `AppModel.init()` builds a `KeychainCredentialStore`, which a ViewInspector unit test should not have to stand up; a binding makes the control testable in isolation and keeps the shared state in exactly one place (`model.autoplay`), which the parents pass as `$model.autoplay`. Behavior is identical.
  2. The spec put the toggle test in `PatataTube/Tests/EpisodesViewTests.swift`, asserting against the toolbar. This plan puts it in a new `PatataTube/Tests/AutoplayToggleTests.swift`, asserting against the control directly. ViewInspector cannot reliably traverse into a `.toolbar` modifier's items, and the toolbar wiring is a one-line instantiation covered by the build plus the manual checklist. `EpisodesViewTests.swift` is therefore left untouched.

---

### Task 1: `playbackEndAction` in PatataTubeKit

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum PlaybackEndAction: Equatable { case advance, dismiss, stop }` and
  `public func playbackEndAction(autoplay: Bool, isForeground: Bool) -> PlaybackEndAction`. Task 2 calls both.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class PlaybackEndActionTests: XCTestCase {
    func testAutoplayOnAdvancesInForeground() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: true), .advance)
    }

    func testAutoplayOnAdvancesWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: true, isForeground: false), .advance)
    }

    func testAutoplayOffDismissesInForeground() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: true), .dismiss)
    }

    func testAutoplayOffStopsWhenBackgrounded() {
        XCTAssertEqual(playbackEndAction(autoplay: false, isForeground: false), .stop)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackEndActionTests`
Expected: FAIL — compile error, `cannot find 'playbackEndAction' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift`:

```swift
import Foundation

/// What the player does when the current item plays to the end.
public enum PlaybackEndAction: Equatable, Sendable {
    /// Play the next playable video in the queue.
    case advance
    /// Close the player.
    case dismiss
    /// Pause and leave the player mounted (nothing dismisses while backgrounded).
    case stop
}

/// The autoplay flag governs both foreground and background: with autoplay on a
/// finished video always rolls into the next one; with it off playback ends where
/// it is — dismissing when the user is looking, pausing when they are not.
public func playbackEndAction(autoplay: Bool, isForeground: Bool) -> PlaybackEndAction {
    if autoplay { return .advance }
    return isForeground ? .dismiss : .stop
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackEndActionTests`
Expected: PASS — `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackEndAction.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackEndActionTests.swift
git commit -m "feat: add playbackEndAction decision function"
```

---

### Task 2: Autoplay state on AppModel, wired into VideoPlayerView

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift:13-14` (add a published property beside `baseURLText`/`tokenText`)
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift:144-158` (`bindPlayToEnd`)

**Interfaces:**
- Consumes: `playbackEndAction(autoplay:isForeground:)` and `PlaybackEndAction` from Task 1.
- Produces: `AppModel.autoplay: Bool` (default `false`), read and written by Tasks 3 and 4 via `$model.autoplay`.

No automated test here: `bindPlayToEnd` needs a live `AVPlayer`, a notification, and `UIApplication.shared.applicationState`. Task 1 covers the decision logic; the wiring is verified by a build plus the manual checklist added in Task 4.

- [ ] **Step 1: Add the state to AppModel**

In `ios/PatataTube/Sources/AppModel.swift`, directly after the existing published properties:

```swift
    @Published var baseURLText: String
    @Published var tokenText: String

    /// When on, a finished video rolls into the next one in the queue. Session-only
    /// by design — it resets to off on relaunch, so a long queue can never keep
    /// playing across launches unnoticed.
    @Published var autoplay: Bool = false
```

- [ ] **Step 2: Replace the end-of-item branch in VideoPlayerView**

In `ios/PatataTube/Sources/VideoPlayerView.swift`, replace `bindPlayToEnd()` in full:

```swift
    /// Rebind end-of-item handling to the current item. `applicationState` and
    /// `model.autoplay` are read at fire time — closure-captured copies would be
    /// frozen at bind time.
    private func bindPlayToEnd() {
        removePlayToEndObserver()
        playToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem, queue: .main
        ) { _ in
            Task { @MainActor in
                switch playbackEndAction(
                    autoplay: model.autoplay,
                    isForeground: UIApplication.shared.applicationState == .active
                ) {
                case .advance:
                    advance(by: 1)
                case .dismiss:
                    dismiss()
                case .stop:
                    player?.pause()
                }
            }
        }
    }
```

Leave `advance(by:)` alone — its existing queue-end fallback (pause, then dismiss when foreground) already gives the required "dismiss at the end of the queue" behavior.

- [ ] **Step 3: Build the app target**

Run from `ios/PatataTube`:
```bash
xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the existing app test suite for regressions**

Run from `ios/PatataTube`:
```bash
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/VideoPlayerView.swift
git commit -m "feat: gate end-of-video behavior on an autoplay flag"
```

---

### Task 3: Autoplay icon asset and the shared AutoplayToggle control

**Files:**
- Create: `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/autoplay.svg` (source, for regeneration)
- Create: `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/autoplay.png`, `autoplay@2x.png`, `autoplay@3x.png`
- Create: `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/Contents.json`
- Create: `ios/PatataTube/Sources/AutoplayToggle.swift`
- Test: `ios/PatataTube/Tests/AutoplayToggleTests.swift`

**Interfaces:**
- Consumes: `AppModel.autoplay` from Task 2 (only at the call site, in Task 4).
- Produces: `struct AutoplayToggle: View` with the single initializer parameter `isOn: Binding<Bool>`, and the asset-catalog image named `"Autoplay"`. Task 4 instantiates it as `AutoplayToggle(isOn: $model.autoplay)`.

- [ ] **Step 1: Fetch the source SVG and render the PNGs**

```bash
mkdir -p ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset
cd ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset
curl -sfL -o autoplay.svg "https://files.chiq.me/files/929aafa2-ad52-4e89-b69c-44535e4f4e40-autoplay-svgrepo-com.svg"
export PATH="/opt/homebrew/bin:$PATH"
rsvg-convert -w 24 -h 24 autoplay.svg -o autoplay.png
rsvg-convert -w 48 -h 48 autoplay.svg -o autoplay@2x.png
rsvg-convert -w 72 -h 72 autoplay.svg -o autoplay@3x.png
```

Verify: `file autoplay*.png` reports `24 x 24`, `48 x 48`, `72 x 72` PNG images.

- [ ] **Step 2: Write the imageset Contents.json**

Create `ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset/Contents.json`. `template-rendering-intent: template` is what makes the glyph tint with the control instead of rendering as flat black — without it the icon is invisible in dark mode.

```json
{
  "images" : [
    {
      "filename" : "autoplay.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "autoplay@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "autoplay@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
```

- [ ] **Step 3: Write the failing test**

Create `ios/PatataTube/Tests/AutoplayToggleTests.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it fails**

Run from `ios/PatataTube`:
```bash
xcodegen generate
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/AutoplayToggleTests
```
Expected: FAIL — compile error, `cannot find 'AutoplayToggle' in scope`.

- [ ] **Step 5: Write the control**

Create `ios/PatataTube/Sources/AutoplayToggle.swift`:

```swift
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
```

- [ ] **Step 6: Run test to verify it passes**

Run from `ios/PatataTube`:
```bash
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/AutoplayToggleTests
```
Expected: `** TEST SUCCEEDED **`, both tests passing.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/AutoplayToggle.swift ios/PatataTube/Tests/AutoplayToggleTests.swift ios/PatataTube/Sources/Assets.xcassets/Autoplay.imageset
git commit -m "feat: add shared autoplay toggle control and icon asset"
```

---

### Task 4: Toolbar wiring and manual-test documentation

**Files:**
- Modify: `ios/PatataTube/Sources/EpisodesView.swift:55-71` (the `.toolbar` block)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (the `.topBarTrailing` items in the `.toolbar` block, near the refresh and upload buttons)
- Modify: `ios/README.md:166-181` (background-audio and auto-advance checklists)

**Interfaces:**
- Consumes: `AutoplayToggle(isOn:)` from Task 3 and `AppModel.autoplay` from Task 2.
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Add the toggle to the EpisodesView toolbar**

In `ios/PatataTube/Sources/EpisodesView.swift`, add a new item **before** the existing download-all item so the switch renders to its left:

```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AutoplayToggle(isOn: $model.autoplay)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { @MainActor in
                        await downloadAll()
                    }
                } label: {
                    if downloadState.isDownloading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(downloadState.isDownloading || !downloadState.canDownloadAll)
                .accessibilityLabel("Download all episodes")
            }
        }
```

`model` is already an `@EnvironmentObject` in this view, so no new property is needed.

- [ ] **Step 2: Add the toggle to the VideoGridView toolbar**

In `ios/PatataTube/Sources/VideoGridView.swift`, add a matching item to the existing `.topBarTrailing` group, immediately before the refresh button:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    AutoplayToggle(isOn: $model.autoplay)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }
```

`model` is already an `@EnvironmentObject` here too.

- [ ] **Step 3: Build and run the full test suite**

Run from `ios/PatataTube`:
```bash
xcodegen generate
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Update the manual checklists in ios/README.md**

Two existing lines now describe behavior this change replaces. In the **Background audio** section, replace:

```
- [ ] Video ends while locked or backgrounded → playback advances to the next playable queue item; playback stops when no playable item remains
```

with:

```
- [ ] Autoplay on, video ends while locked or backgrounded → playback advances to the next playable queue item; playback stops when no playable item remains
- [ ] Autoplay off, video ends while locked or backgrounded → audio stops at the end; returning to the app shows the paused end frame
```

In the **Lock-screen next/previous + auto-advance** numbered list, replace items 4 and 5:

```
4. Locked: a video ending auto-advances to the next one.
5. Foreground: a video ending dismisses the player (unchanged behavior).
```

with:

```
4. Locked with autoplay on: a video ending auto-advances to the next one.
5. Foreground with autoplay off: a video ending dismisses the player.
```

Then add a new section immediately after that numbered list:

```markdown
### Autoplay toggle

1. The switch sits in the toolbar of both the grid and a show's episode list;
   flipping it in one place shows it flipped in the other.
2. Autoplay on, play an episode from a show → it ends → the next episode in list
   order starts automatically.
3. Autoplay on, play the last episode → it ends → the player dismisses.
4. Autoplay off, an episode ends in the foreground → the player dismisses.
5. Relaunch the app → the switch is back to off (it is session-only by design).
6. Lock-screen next/previous keep working with the switch in either position.
```

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/EpisodesView.swift ios/PatataTube/Sources/VideoGridView.swift ios/README.md
git commit -m "feat: show the autoplay toggle in both toolbars"
```

---

## Manual verification after Task 4

Run the app on a device or simulator and walk the new **Autoplay toggle** checklist in `ios/README.md`. The automated tests cover the decision function and the control; only a real player exercises the notification path added in Task 2.
