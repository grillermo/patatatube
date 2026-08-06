# Restoration Task Re-entry Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make boot restoration run exactly once per app launch, so dismissing the video player can never resurrect it or rewrite the navigation path.

**Architecture:** `VideoGridView`'s `.task { await initialLoad(...) }` re-runs every time the grid re-enters the view hierarchy — which is what dismissing a `fullScreenCover` does. Each re-run re-applies a `RestorationState` snapshot read *before* its two `await`s, so it re-presents the just-dismissed player (and sometimes clears `path`). The fix is a launch-scoped, thread-safe one-shot claim (`RestorationGate`) held by `AppModel` and claimed by `initialLoad` before it applies anything, plus a second, independent guard that refuses to overwrite live navigation/playback state even if a restore does run.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM local package (`ios/PatataTubeKit`), XCTest, XcodeGen.

## Global Constraints

- Swift tools/language version: `SWIFT_VERSION: "6.0"`, iOS deployment target `17.0`.
- New logic goes in `ios/PatataTubeKit` (the testable core), not in the app target. The app target holds SwiftUI wiring only.
- All new instrumentation uses `DevLog.event` / `DevLog.error`, never `print`. `DevLog` is compiled out unless the `DEVLOG` condition is set.
- Kit tests are XCTest classes in `ios/PatataTubeKit/Tests/PatataTubeKitTests/`, one file per type, matching `RestorationStoreTests.swift` in style.
- A full parallel `swift test` run has pre-existing unrelated failures (a swift-testing `Fatal error: Index out of range`, occasional `VideoStoreTests` flakes). Verify with **filtered** runs; never treat a full-suite failure alone as a regression.
- The git remote is named `github`, not `origin`.
- Do **not** deploy at the end of this plan without being asked — the AltStore source is currently on instrumented build v1.1.60.

---

## Background: the evidence this plan is built on

From `log/ios.jsonl`, build v1.1.60 (captured 2026-08-03 05:03 UTC):

```
seq 310  pull-down dismiss            inst B8282225, video 180
seq 311  grid playing changed 180 -> nil
seq 315  grid playing changed nil -> 180     +86ms   <- no "begin playback" record
seq 330  player dismissed             inst B8282225
seq 331  player appear                inst B8282225   start_paused:"true"
```

- No `play requested` / `begin playback` precedes the resurrection → nothing called `play()`.
- `start_paused:"true"` is set in exactly one place: the restore branch of `initialLoad()` (`VideoGridView.swift`, the `PlaybackQueue(... startPaused: true)` call).
- `initial load applying` appears **152 times** in one 30-second capture against 5 real player mounts, in bursts that begin the instant a cover dismisses.
- `grid path changed` bounces `show(Bluey)` → `""` → `show(Bluey)` → `""` (seq 137–155): re-runs that land while `store.videos` is momentarily empty resolve the `.show` route to nothing and assign `path = []`. That is the "back button needs ~4 taps" symptom — the stack is rewritten under the tap.

## File Structure

- **Create** `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationGate.swift` — one-shot claim, thread-safe, launch-scoped. ~30 lines.
- **Create** `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationGateTests.swift` — tests for the above.
- **Create** `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationApplyDecision.swift` — pure decision: given live path/player state, may a restored snapshot be applied? ~35 lines.
- **Create** `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationApplyDecisionTests.swift` — tests for the above.
- **Modify** `ios/PatataTube/Sources/AppModel.swift` — hold one `RestorationGate`.
- **Modify** `ios/PatataTube/Sources/VideoGridView.swift` — `initialLoad` claims the gate; applies path/player through `RestorationApplyDecision`.
- **Modify** `docs/restoration-buggy.md` — record root cause + fix, close the investigation.
- **Modify** `ios/README.md` — add the repro to the manual checklist.

Task 1 and Task 2 are independent pure-logic units. Task 3 wires both into the app. Task 4 is documentation and verification.

---

### Task 1: `RestorationGate` — one-shot claim

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationGate.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public final class RestorationGate: @unchecked Sendable`, with `public init()`, `public func claim() -> Bool` (returns `true` exactly once per instance, `false` forever after), and `public func reset()` (test/debug only — also used by the "Clear Restoration" quick action path in Task 3).

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationGateTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class RestorationGateTests: XCTestCase {
    func testFirstClaimSucceedsAndLaterOnesDoNot() {
        let gate = RestorationGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testSeparateGatesAreIndependent() {
        XCTAssertTrue(RestorationGate().claim())
        XCTAssertTrue(RestorationGate().claim())
    }

    func testResetAllowsOneMoreClaim() {
        let gate = RestorationGate()
        XCTAssertTrue(gate.claim())
        gate.reset()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    /// The `.task` that claims this can be restarted from more than one
    /// SwiftUI update at once; exactly one of them must win.
    func testConcurrentClaimsYieldExactlyOneWinner() {
        let gate = RestorationGate()
        let winners = NSMutableArray()
        let lock = NSLock()
        let group = DispatchGroup()

        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                let won = gate.claim()
                if won {
                    lock.lock()
                    winners.add(true)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(winners.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationGateTests`
Expected: FAIL — `cannot find 'RestorationGate' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationGate.swift`:

```swift
import Foundation

/// One-shot permission to apply saved restoration state, scoped to an app
/// launch rather than to a view.
///
/// `VideoGridView`'s restore lives in a `.task`, and SwiftUI restarts a
/// `.task` whenever its view re-enters the hierarchy — which is exactly what
/// dismissing a `fullScreenCover` does. Left ungated, every player dismissal
/// re-ran boot restoration and re-presented the player it had just dismissed
/// (2026-08-02; see `docs/restoration-buggy.md`). The gate has to outlive the
/// view, so it is held by `AppModel`, not by `@State`.
public final class RestorationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// Returns `true` to exactly one caller per launch. Safe to call from any
    /// thread and from overlapping SwiftUI updates.
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    /// Re-arms the gate. Used by the "Clear Restoration" quick action so a
    /// wipe-and-relaunch-free reset behaves like a fresh launch, and by tests.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        claimed = false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationGateTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RestorationGate.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationGateTests.swift
git commit -m "feat(ios): add RestorationGate, a launch-scoped one-shot claim"
```

---

### Task 2: `RestorationApplyDecision` — never clobber live state

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationApplyDecision.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationApplyDecisionTests.swift`

**Interfaces:**
- Consumes: nothing (pure value logic; deliberately takes `Bool`s rather than the view's types so it stays testable without SwiftUI).
- Produces: `public enum RestorationApplyDecision` with two static methods:
  - `public static func shouldApplyPath(restoredIsEmpty: Bool, liveIsEmpty: Bool) -> Bool`
  - `public static func shouldApplyPlayer(hasRestoredPlayer: Bool, hasLivePlayer: Bool) -> Bool`

This is the second, independent layer: even if something re-enters restoration (a future refactor, a `reset()`), it must not overwrite navigation or playback the user is currently in.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationApplyDecisionTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class RestorationApplyDecisionTests: XCTestCase {
    // MARK: path

    func testAppliesRestoredPathOnlyOntoAnEmptyStack() {
        XCTAssertTrue(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: false, liveIsEmpty: true))
    }

    func testDoesNotRewriteAStackTheUserIsAlreadyOn() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: false, liveIsEmpty: false))
    }

    /// The regression that popped EpisodesView mid-tap: a restore that
    /// resolved to nothing must never clear a live stack.
    func testEmptyRestoredPathNeverClearsALiveStack() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: true, liveIsEmpty: false))
    }

    func testEmptyOntoEmptyIsANoOp() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: true, liveIsEmpty: true))
    }

    // MARK: player

    func testRestoresPlayerWhenNothingIsPlaying() {
        XCTAssertTrue(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: true, hasLivePlayer: false))
    }

    /// The resurrection bug: a restore landing while the player is up (or has
    /// just been dismissed and the snapshot is stale) must not re-present it.
    func testDoesNotReplaceALivePlayer() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: true, hasLivePlayer: true))
    }

    func testNoRestoredPlayerIsANoOp() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: false, hasLivePlayer: false))
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: false, hasLivePlayer: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationApplyDecisionTests`
Expected: FAIL — `cannot find 'RestorationApplyDecision' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationApplyDecision.swift`:

```swift
import Foundation

/// Whether a restored snapshot may be written over what is on screen right
/// now. Restoration is a *launch* concern: it seeds empty state, it never
/// takes state away from a running session.
///
/// Second layer behind `RestorationGate`. The gate stops restoration from
/// running twice; this stops a restore that does run from undoing live
/// navigation or playback.
public enum RestorationApplyDecision {
    /// Restored paths seed an empty stack only. A restore that resolved to
    /// nothing must never pop the screen the user is on.
    public static func shouldApplyPath(restoredIsEmpty: Bool, liveIsEmpty: Bool) -> Bool {
        !restoredIsEmpty && liveIsEmpty
    }

    /// A restored player is presented only when nothing is presented. Anything
    /// else is either a duplicate presentation or a resurrection of a player
    /// the user just dismissed.
    public static func shouldApplyPlayer(hasRestoredPlayer: Bool, hasLivePlayer: Bool) -> Bool {
        hasRestoredPlayer && !hasLivePlayer
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationApplyDecisionTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RestorationApplyDecision.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationApplyDecisionTests.swift
git commit -m "feat(ios): add RestorationApplyDecision so restore never clobbers live state"
```

---

### Task 3: Wire the gate and the decision into the app

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift` (property next to `let restorationStore = RestorationStore()`, and `clearRestoration()`)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (`initialLoad`, ~line 479)

**Interfaces:**
- Consumes: `RestorationGate.claim()`, `RestorationGate.reset()`, `RestorationApplyDecision.shouldApplyPath(restoredIsEmpty:liveIsEmpty:)`, `RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer:hasLivePlayer:)` (Tasks 1–2).
- Produces: `AppModel.restorationGate: RestorationGate`. No other new app-target API.

There is no automated iOS UI test target for this; verification is the build plus the device repro in Task 4.

- [ ] **Step 1: Add the gate to `AppModel`**

In `ios/PatataTube/Sources/AppModel.swift`, directly below `let restorationStore = RestorationStore()`:

```swift
    /// Restoration is a launch concern, and `VideoGridView`'s restore lives in
    /// a `.task` that SwiftUI restarts whenever the grid re-enters the
    /// hierarchy (every `fullScreenCover` dismissal). The gate lives here, not
    /// in the view, so exactly one run per launch can apply saved state.
    let restorationGate = RestorationGate()
```

- [ ] **Step 2: Re-arm the gate when restoration is cleared**

Still in `AppModel.swift`, replace the body of `clearRestoration()`:

```swift
    /// Wipes the saved path/player/scroll state. The running session keeps
    /// whatever is on screen — the point is a clean slate for the *next*
    /// launch, so a bad restored state can't be replayed forever.
    func clearRestoration() {
        restorationStore.clear()
        restorationGate.reset()
        DevLog.event(.state, "restoration cleared")
    }
```

- [ ] **Step 3: Gate `initialLoad` and route its writes through the decision**

In `ios/PatataTube/Sources/VideoGridView.swift`, replace the whole `initialLoad(scrollProxy:)` function with:

```swift
    /// Order is load-bearing: the restored path and player resolve against
    /// `store.videos`, which only exists after `bootLoad()` returns, and the
    /// search text has to be applied before `filteredVideos` (which both
    /// depend on) is read.
    ///
    /// Claims `model.restorationGate` first. SwiftUI restarts a `.task` every
    /// time its view re-enters the hierarchy, and dismissing the player's
    /// `fullScreenCover` does exactly that — ungated, each dismissal re-ran
    /// this function against a snapshot read before its `await`s and
    /// re-presented the player it had just dismissed, or cleared `path` and
    /// popped `EpisodesView` under the user's tap
    /// (`docs/restoration-buggy.md`).
    private func initialLoad(scrollProxy: ScrollViewProxy) async {
        guard model.restorationGate.claim() else {
            DevLog.event(.nav, "initial load skipped", ["reason": "already restored"])
            return
        }

        let api = APIClient(store: model.credentials)
        if let list = try? await api.classifications() { classifications = list }

        let restored = model.restorationStore.load()
        await store.bootLoad()

        searchText = restored.search
        activeSearch = restored.search

        // An explicit launch intent (home-screen quick action) must not be
        // overridden by whatever was playing last session.
        let resolved = RestorationResolver.resolve(
            state: restored,
            videos: store.videos,
            hasPendingQuickAction: QuickActionRouter.shared.pending != nil
        )
        let applyPath = RestorationApplyDecision.shouldApplyPath(
            restoredIsEmpty: resolved.path.isEmpty, liveIsEmpty: path.isEmpty
        )
        let applyPlayer = RestorationApplyDecision.shouldApplyPlayer(
            hasRestoredPlayer: resolved.player != nil, hasLivePlayer: playing != nil
        )
        DevLog.event(.nav, "initial load applying", [
            "path": RestorationTracking.describe(resolved.path),
            "player": resolved.player.map { "\($0.video.id)" } ?? "nil",
            "apply_path": "\(applyPath)",
            "apply_player": "\(applyPlayer)",
        ])
        if applyPath { path = resolved.path }
        if applyPlayer, let player = resolved.player {
            let startSecs = model.resumeStore.resolved(server: player.video.resumeSecs, for: player.video.id)
            playing = PlaybackQueue(
                video: player.video,
                queueSnapshot: player.queue,
                sleepMode: player.sleepMode,
                startSecs: startSecs,
                startPaused: true
            )
        }

        gridTracker.setOrder(currentGridOrder)
        if let anchor = restored.scrollAnchors[RestorationState.gridKey(filter: store.filter)] {
            // LazyVGrid/List need a render pass after the data lands before
            // an off-screen id resolves to a position.
            try? await Task.sleep(nanoseconds: 100_000_000)
            scrollProxy.scrollTo(anchor, anchor: .top)
        }

        // Footprint after the list lands: correlates library size + in-flight
        // downloads with the OOM watchdog kills (PATATATUBE-6, -2).
        MemoryProbe.snapshot("grid-loaded", extra: [
            "video_count": store.videos.count,
            "active_downloads": model.cache.activeDownloads().count,
        ])
    }
```

- [ ] **Step 4: Build the package and the app**

Run:

```bash
cd ios/PatataTubeKit && swift build
cd ../PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (SourceKit diagnostics about "No such module 'PatataTubeKit'" outside Xcode are noise — the `xcodebuild` result is the signal.)

- [ ] **Step 5: Run the two restoration-adjacent kit suites**

Run:

```bash
cd ios/PatataTubeKit
swift test --filter RestorationGateTests
swift test --filter RestorationApplyDecisionTests
swift test --filter RestorationResolverTests
swift test --filter RestorationStoreTests
```

Expected: all PASS. These are filtered runs on purpose (see Global Constraints).

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "fix(ios): restore session state once per launch, not per task restart

Dismissing the player's fullScreenCover puts VideoGridView back in the
hierarchy, which restarts its .task and re-ran boot restoration — 152 runs
in one 30s capture. Each run applied a snapshot read before its awaits, so
it re-presented the dismissed player (start_paused:true) and sometimes
cleared path, popping EpisodesView under the back tap.

Gate the restore on a launch-scoped RestorationGate held by AppModel, and
apply path/player only onto empty state via RestorationApplyDecision."
```

---

### Task 4: Verify on device, then close out the investigation

**Files:**
- Modify: `docs/restoration-buggy.md`
- Modify: `ios/README.md` (manual test checklist)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Capture a clean repro run**

The AltStore source is on instrumented build v1.1.60. Ship this fix as another instrumented build so the same records are available:

```bash
.claude/skills/deploy-ios/deploy-ios.sh --instrumented --yes -m "fix: restoration task re-entry"
```

Then on the iPad, with `./serve` running locally (it truncates `log/ios.jsonl` on start):

1. Trigger the **Clear Restoration** home-screen quick action.
2. Open a TV show, play an episode.
3. Pull down to dismiss the player.
4. Tap the nav-bar back button **once**.

- [ ] **Step 2: Check the log against the fix's predictions**

Run:

```bash
jq -c 'select(.kind=="nav")|{seq,ts,msg,inst:.meta.inst,caller:.meta.caller,meta}' log/ios.jsonl | tail -40
grep -c '"msg":"initial load applying"' log/ios.jsonl
grep -c '"msg":"initial load skipped"' log/ios.jsonl
```

Expected:
- `initial load applying` appears **exactly once**, at launch.
- `initial load skipped` appears once per cover dismissal — this is the bug's mechanism, now inert and visible.
- After `pull-down dismiss`: `grid playing changed <id> -> nil` with **no** following `nil -> <id>`, and **no** second `player appear` reusing the same `inst`.
- One `grid path changed show(...) -> ""` after the single back tap, and no bounce back to `show(...)`.

If `initial load applying` still appears more than once, stop — the gate is not reached (check that `AppModel` is a single instance for the scene) and return to `docs/restoration-buggy.md` rather than adding a second fix.

- [ ] **Step 3: Update the investigation doc**

In `docs/restoration-buggy.md`, change the status line at the top to:

```markdown
Status: **root-caused and fixed** (2026-08-02). Fix:
`docs/superpowers/plans/2026-08-02-restoration-task-reentry-fix.md`.
Ship a clean build (`./deploy patch`) to take the AltStore source off the
instrumented release.
```

And append a "Root cause" section:

```markdown
## Root cause

`VideoGridView`'s `.task { await initialLoad(scrollProxy:) }` is restarted by
SwiftUI every time the grid re-enters the view hierarchy, and presenting or
dismissing the player's `fullScreenCover` does exactly that. Each restart
re-ran boot restoration against a `RestorationState` snapshot loaded *before*
its two `await`s — i.e. from before the dismissal — so it re-presented the
player that had just been dismissed (`startPaused: true`, same view `inst`)
and, on runs where `store.videos` was momentarily empty, resolved the `.show`
route to nothing and assigned `path = []`. Re-presenting the cover took the
grid out of the hierarchy again, which restarted the task again: a
self-sustaining loop (152 restore runs in one 30s capture).

Hypotheses 2, 3 and 4 above are all eliminated: the trigger is neither route
re-resolution, nor gesture residue, nor the `RestorationTracking` save
handlers.

Fixed by `RestorationGate` (one claim per launch, held by `AppModel` so it
outlives the view) plus `RestorationApplyDecision` (a restore may seed empty
state, never overwrite a live path or a live player).
```

- [ ] **Step 4: Add the repro to the iOS manual checklist**

In `ios/README.md`, append to the manual test checklist:

```markdown
- **Player dismissal does not resurrect the player.** Open a show, play an
  episode, pull down to dismiss. The player must stay dismissed, and a single
  tap on the nav-bar back button must return to the shows list. (Regression
  test for the restoration task re-entry loop, 2026-08-02.)
```

- [ ] **Step 5: Commit**

```bash
git add docs/restoration-buggy.md ios/README.md
git commit -m "docs: record restoration task re-entry root cause and repro"
```

- [ ] **Step 6: Ship a clean build (only once Step 2 passed)**

```bash
.claude/skills/deploy-ios/deploy-ios.sh patch
```

This takes the public AltStore source off the instrumented release. Confirm `ios/apps.json` no longer carries the `[DEVLOG]` marker.
