# iOS Error Banner Swipe Dismissal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow a person to dismiss the iOS video grid’s red error banner with a predominantly horizontal flick in either direction.

**Architecture:** Keep the banner and all error ownership in `VideoGridView`. Add a small internal decision helper for the drag-threshold rule and local SwiftUI state for the visual horizontal offset; the gesture clears only `store.errorText` after a qualifying flick.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, ViewInspector, XcodeGen-generated iOS test target.

## Global Constraints

- Support iOS 17.0 and Swift 6.0 as configured in `ios/PatataTube/project.yml`.
- Do not change how any load, preparation, or download path creates `store.errorText`.
- Treat only a horizontal-dominant drag as a dismiss attempt so vertical scrolling remains unaffected.
- Require a 100-point horizontal translation in either direction to dismiss.
- Keep the scope to the existing `VideoGridView` bottom error banner.

---

## File Structure

- Modify `ios/PatataTube/Sources/VideoGridView.swift`: own the banner offset, expose the pure dismissal decision for tests, and attach the horizontal drag behavior to the existing banner.
- Create `ios/PatataTube/Tests/VideoGridViewTests.swift`: prove the threshold and direction rules through the app target’s internal API.

### Task 1: Define and Test the Dismissal Rule

**Files:**

- Modify: `ios/PatataTube/Sources/VideoGridView.swift:24-27`
- Create: `ios/PatataTube/Tests/VideoGridViewTests.swift`

**Interfaces:**

- Consumes: `CGSize.translation` from SwiftUI’s `DragGesture.Value`.
- Produces: `VideoGridView.shouldDismissErrorBanner(translation: CGSize) -> Bool`, returning `true` only for a horizontal-dominant translation whose absolute width is at least 100 points.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTube/Tests/VideoGridViewTests.swift`:

```swift
import SwiftUI
import Testing
@testable import PatataTube

@Suite("Video grid error banner", .serialized)
@MainActor
struct VideoGridViewErrorBannerTests {
    @Test func dismissesOnlyForDominantHorizontalFlicksPastThreshold() {
        #expect(VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 100, height: 20)
        ))
        #expect(VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: -100, height: 20)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 99, height: 0)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 140, height: 141)
        ))
    }
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run from `ios/PatataTube`:

```bash
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/VideoGridViewErrorBannerTests
```

Expected: compilation fails because `VideoGridView.shouldDismissErrorBanner(translation:)` does not exist.

- [ ] **Step 3: Write the minimal production rule**

Near the other stored properties in `VideoGridView`, add this internal helper:

```swift
static func shouldDismissErrorBanner(translation: CGSize) -> Bool {
    abs(translation.width) >= 100 && abs(translation.width) > abs(translation.height)
}
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run the same `xcodebuild test` command from Step 2.

Expected: `VideoGridViewErrorBannerTests` passes.

- [ ] **Step 5: Commit the tested rule**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Tests/VideoGridViewTests.swift
git commit -m "test: cover error banner dismiss rule"
```

### Task 2: Add the Interactive Banner Gesture

**Files:**

- Modify: `ios/PatataTube/Sources/VideoGridView.swift:25-27,313-320`
- Test: `ios/PatataTube/Tests/VideoGridViewTests.swift`

**Interfaces:**

- Consumes: `VideoGridView.shouldDismissErrorBanner(translation:) -> Bool` from Task 1 and `store.errorText` from the existing `VideoStore` environment object.
- Produces: a bottom error banner that follows a dominant horizontal drag, clears `store.errorText` after a qualifying release, and springs back after any other release.

- [ ] **Step 1: Extend the existing test boundary with the exact threshold cases**

In `VideoGridViewErrorBannerTests`, keep the existing test and add:

```swift
#expect(!VideoGridView.shouldDismissErrorBanner(
    translation: CGSize(width: -99, height: 0)
))
#expect(!VideoGridView.shouldDismissErrorBanner(
    translation: CGSize(width: 0, height: 120)
))
```

- [ ] **Step 2: Run the focused test to verify it still passes before UI wiring**

Run from `ios/PatataTube`:

```bash
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/VideoGridViewErrorBannerTests
```

Expected: the pure rule test passes, establishing the gesture contract before presentation wiring changes.

- [ ] **Step 3: Add local offset state and wire the drag into `errorBanner(_:)`**

Add this state with the other `@State` properties:

```swift
@State private var errorBannerOffset: CGFloat = 0
```

Replace `errorBanner(_:)` with:

```swift
private func errorBanner(_ text: String) -> some View {
    VStack {
        Spacer()
        Text(text)
            .font(.caption)
            .padding()
            .background(.red.opacity(0.85))
            .foregroundStyle(.white)
            .cornerRadius(8)
            .offset(x: errorBannerOffset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        errorBannerOffset = value.translation.width
                    }
                    .onEnded { value in
                        if Self.shouldDismissErrorBanner(translation: value.translation) {
                            store.errorText = nil
                        }
                        withAnimation(.spring()) {
                            errorBannerOffset = 0
                        }
                    }
            )
            .padding()
    }
}
```

This leaves vertical gestures unclaimed by the banner, clears only the existing error text when the pure rule passes, and restores the banner after a short or vertical drag.

- [ ] **Step 4: Run focused and full iOS tests**

Run from `ios/PatataTube`:

```bash
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/VideoGridViewErrorBannerTests
xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: the focused suite and the complete `PatataTubeTests` target pass.

- [ ] **Step 5: Manually verify the touch interaction in the simulator**

1. Set the base URL to an unreachable address and refresh so the red banner appears.
2. Swipe the banner left past 100 points; confirm it disappears.
3. Trigger another error and swipe it right past 100 points; confirm it disappears.
4. Trigger another error and make a short horizontal drag; confirm it returns to the bottom.
5. Trigger another error and scroll the grid vertically over it; confirm the banner remains and the grid scroll behaves normally.

- [ ] **Step 6: Commit the interaction**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Tests/VideoGridViewTests.swift
git commit -m "feat: dismiss error banner with swipe"
```

