# iOS Cache-First Classification Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping a classification tab shows that classification's cached videos (or skeletons) instantly, then refreshes from the API — no more staring at the previous tab's videos during the network round-trip.

**Architecture:** Add `VideoStore.switchFilter(to:)` that sets the filter, swaps `videos` to the new classification's disk cache (or `[]`) synchronously, then calls the existing `load()` for the network refresh. `VideoGridView` renders a skeleton grid whenever `store.isLoading && filteredVideos.isEmpty`, so the grid is never empty and never shows the old tab's content.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test`/`#expect`), Combine `ObservableObject`. Logic in the `PatataTubeKit` SPM package; UI in the `PatataTube` XcodeGen app target.

## Global Constraints

- `VideoStore` is `@MainActor`; all its methods and the tests touching it are `@MainActor`.
- `load()`, `bootLoad()`, the cache format, and `VideoAPI` stay unchanged — only additive.
- `VideoListCache` is already per-classification (`fileURL` = `<classification|all>.json`). Do not change it.
- Skeleton cell aspect ratios (disk-confirmed against the preview cache): tv + movies = **2:3**, default = **16:9**.
- iOS has no automated UI test target — `PatataTubeKit` logic is unit-tested; app-target UI is verified by build + the `ios/README.md` manual checklist.

---

### Task 1: `VideoStore.switchFilter(to:)` (cache-first tab switch)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Consumes: existing `loadCache() -> [Video]?` (private, reads `filter`), `load()`, `filter`, `videos`, `VideoListCache.save/load(classification:)`.
- Produces: `public func switchFilter(to value: String?) async` — sets `filter`, replaces `videos` with the new filter's cache (or `[]`), then refreshes via `load()`.

- [ ] **Step 1: Add a suspend hook to the test `FakeAPI`**

The existing `FakeAPI.videos(...)` returns immediately, so a test can't observe the
mid-flight state (cache shown, network not yet returned). Add an async hook that
fires inside `videos(...)` before it returns. Edit the `FakeAPI` class near the top
of `VideoStoreTests.swift`:

Add the stored property alongside the other vars:

```swift
    /// Fires inside videos(...) before it returns, so a test can observe
    /// VideoStore's state after the synchronous cache swap but before the
    /// network result lands.
    var beforeVideosReturn: (@Sendable () async -> Void)?
```

Change `videos(classification:)` to await the hook first:

```swift
    func videos(classification: String?) async throws -> [Video] {
        loadCount += 1
        if let beforeVideosReturn { await beforeVideosReturn() }
        if let videosError { throw videosError }
        if throwOnVideos { throw APIError.badStatus(503) }
        if let c = classification { return videosToReturn.filter { $0.classification == c } }
        return videosToReturn
    }
```

- [ ] **Step 2: Write the failing tests**

Append to `VideoStoreTests.swift`:

```swift
@MainActor @Test func switchFilterShowsCachedListBeforeNetworkReturns() async {
    let cache = tempCache()
    cache.save([makeVideo(id: 9, classification: "adults")], classification: "adults")
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, classification: "adults"),
                          makeVideo(id: 2, classification: "adults")]
    let store = VideoStore(api: api, cache: cache)

    api.beforeVideosReturn = { @MainActor in
        // Cache swap already happened; network result not yet applied.
        #expect(store.filter == "adults")
        #expect(store.videos.map(\.id) == [9])
        #expect(store.isLoading == true)
    }
    await store.switchFilter(to: "adults")

    // After the network returns, the API result replaces the cached list.
    #expect(store.videos.map(\.id) == [1, 2])
    #expect(store.isLoading == false)
    #expect(cache.load(classification: "adults")?.map(\.id) == [1, 2])
}

@MainActor @Test func switchFilterShowsEmptyThenFillsWhenNoCache() async {
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 5, classification: "children")]
    let store = VideoStore(api: api, cache: tempCache())

    api.beforeVideosReturn = { @MainActor in
        // No cache for "children" -> grid empty (skeletons) while loading.
        #expect(store.videos.isEmpty)
        #expect(store.isLoading == true)
    }
    await store.switchFilter(to: "children")

    #expect(store.videos.map(\.id) == [5])
    #expect(store.filter == "children")
}

@MainActor @Test func switchFilterNeverShowsPreviousFiltersVideos() async {
    let cache = tempCache()
    let api = FakeAPI()
    api.videosToReturn = [makeVideo(id: 1, classification: "adults"),
                          makeVideo(id: 7, classification: "children")]
    let store = VideoStore(api: api, cache: cache)

    // Land on "adults" first (populates videos with id 1 and caches it).
    await store.switchFilter(to: "adults")
    #expect(store.videos.map(\.id) == [1])

    // Switch to "children" (no cache): must not keep showing adults' [1].
    api.beforeVideosReturn = { @MainActor in
        #expect(store.videos.isEmpty)
    }
    await store.switchFilter(to: "children")
    #expect(store.videos.map(\.id) == [7])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter switchFilter`
Expected: FAIL — `value of type 'VideoStore' has no member 'switchFilter'`.

- [ ] **Step 4: Implement `switchFilter`**

In `VideoStore.swift`, add after `load()` (around line 81):

```swift
    /// Tab-switch path: swap to the new classification's cached list instantly
    /// (or an empty list, which the grid renders as skeletons), then refresh
    /// from the network. Mirrors bootLoad()'s cache-first behavior so switching
    /// tabs never lingers on the previous classification's videos.
    public func switchFilter(to value: String?) async {
        filter = value
        let cached = await loadCache()   // loadCache() reads `filter`, now updated
        videos = cached ?? []
        await load()
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter switchFilter`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the full package suite (no regressions)**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (all existing tests still green).

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): cache-first classification switch in VideoStore"
```

---

### Task 2: Skeleton grid + tab wiring in `VideoGridView`

**Files:**
- Create: `ios/PatataTube/Sources/SkeletonGrid.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (tab action ~line 214-221; grid branches ~line 74-115)

**Interfaces:**
- Consumes: `VideoStore.switchFilter(to:)` (Task 1), `store.isLoading`, `filteredVideos`, `store.filter`, `columns`, `cellSize`.
- Produces: `SkeletonGrid` view; `VideoGridView` shows it whenever `store.isLoading && filteredVideos.isEmpty`.

- [ ] **Step 1: Create the `SkeletonGrid` view**

Create `ios/PatataTube/Sources/SkeletonGrid.swift`:

```swift
import SwiftUI

/// Placeholder cells shown while a classification's videos load and none are
/// yet on screen. Keeps the grid from ever appearing empty or lingering on the
/// previous tab's content. Aspect ratios match the real cells: tv/movies use
/// 2:3 Plex posters, everything else uses a 16:9 frame.
struct SkeletonGrid: View {
    let columns: [GridItem]
    let aspectRatio: CGFloat
    /// tv cells carry a title + episode-count line under the poster; draw stubs.
    var showsTextBars: Bool = false
    var count: Int = 8

    @State private var pulse = false

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .aspectRatio(aspectRatio, contentMode: .fit)
                    if showsTextBars {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 60, height: 10)
                    }
                }
            }
        }
        .padding()
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Wire the tabs to `switchFilter`**

In `VideoGridView.swift`, replace the `tab(title:value:)` button action (currently
`store.filter = value` + `Task { await store.load() }`):

```swift
    private func tab(title: String, value: String?) -> some View {
        Button(title) {
            Task { await store.switchFilter(to: value) }
        }
        .buttonStyle(.borderedProminent)
        .tint(store.filter == value ? .accentColor : .gray)
    }
```

- [ ] **Step 3: Add a skeleton gate to the grid body**

In `VideoGridView.swift`, wrap the three-branch grid area (inside the `ScrollView`,
after `filterTabs`) so skeletons show when loading with nothing to display.
Replace the `if store.filter == "tv" { ... } else if ... movies ... { ... } else { ... }`
block so it is guarded by a leading loading check:

```swift
                if store.isLoading && filteredVideos.isEmpty {
                    if store.filter == "tv" || store.filter == "movies" {
                        SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                                     showsTextBars: store.filter == "tv")
                    } else {
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0)
                    }
                } else if store.filter == "tv" {
                    ShowsView(
                        videos: filteredVideos,
                        onPlay: { video, queue in
                            play(video, queueSnapshot: queue)
                        },
                        onDownload: { await download($0) }
                    )
                } else if store.filter == "movies" {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredVideos) { video in
                            MovieCell(
                                video: video,
                                cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                            )
                        }
                    }
                    .padding()
                } else {
                    // ...existing default VideoCell LazyVGrid unchanged...
                }
```

> Note: `columns` uses `.adaptive(minimum: cellSize)` (cellSize = 220) for movies/default.
> The tv `ShowsView` uses its own `adaptive(minimum: 160)` internally, but the skeleton
> here uses `VideoGridView.columns` for simplicity — acceptable, since skeletons are
> transient and only need believable poster shapes, not pixel-identical column counts.

- [ ] **Step 4: Regenerate the Xcode project (new file must be picked up)**

Run: `cd ios/PatataTube && xcodegen generate`
Expected: `Generated project ... PatataTube.xcodeproj` (SkeletonGrid.swift now in the target).

- [ ] **Step 5: Build the app target**

Run:
```bash
cd ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build
```
Expected: `** BUILD SUCCEEDED **`. (If that simulator name is unavailable, pick any
booted iPad simulator from `xcrun simctl list devices`.)

- [ ] **Step 6: Manual verification (per `ios/README.md` — no UI test target)**

Run the app in the simulator, then confirm:
1. From a populated tab, tap a **different** classification you've visited before → its
   videos appear immediately (from cache), no flash of the previous tab's videos.
2. Tap a classification with **no cache** (fresh install / cleared cache) → skeleton
   cells appear, then real videos replace them. The grid is never empty mid-load.
3. `tv` / `movies` skeletons are portrait (2:3); other tabs' skeletons are 16:9.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/SkeletonGrid.swift \
        ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/PatataTube.xcodeproj
git commit -m "feat(ios): skeleton grid + cache-first tab switching in VideoGridView"
```

---

## Self-Review

**Spec coverage:**
- `switchFilter(to:)` cache-first swap → Task 1. ✓
- Cache-miss → skeletons, never empty, never old tab → Task 1 (`videos = []`) + Task 2 gate. ✓
- Skeletons for tv + movies (2:3) and default (16:9), poster-sized → Task 2 `SkeletonGrid` + branch. ✓
- `load()`/cache/API unchanged → Task 1 is additive; verified by full-suite run (Task 1 Step 6). ✓
- Test asserting cache-before-network + save → Task 1 Steps 1-2. ✓
- iOS-only, no SSR change → no web files touched. ✓

**Placeholder scan:** No TBD/TODO; the one `// ...existing default VideoCell LazyVGrid unchanged...` marker points at code left verbatim in place (not new code to write). ✓

**Type consistency:** `switchFilter(to:)`, `SkeletonGrid(columns:aspectRatio:showsTextBars:)`, `store.isLoading`, `filteredVideos`, `columns`, `cellSize` used consistently across both tasks. ✓
