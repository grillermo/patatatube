# iOS Tab Navigation + Video Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the toolbar classification `Picker` with a Videos / TV / Movies `TabView`, and put a ShowsView-style group screen (children, adults, anabel, asmr) at the root of the Videos tab.

**Architecture:** `MediaTab` (new, PatataTubeKit) is the top-level selector; `VideoStore.filter` stays the single source of truth for what is loaded, and tab selection drives `switchFilter` exactly as the picker did. `RootTabView` (new) owns tab selection and hosts three `VideoGridView` instances, one per tab, each with its own `NavigationStack`. The Videos tab's root renders `GroupsView`, whose cards push `Route.group(name:)` onto the existing `defaultGrid`. Group card art comes from `GroupPosterStore`, a UserDefaults record of each group's newest `preview_url` written whenever that group's list loads — no extra network calls.

**Tech Stack:** SwiftUI (iOS 17+ APIs already in use), SwiftPM package `PatataTubeKit`, XCTest, XcodeGen; FastAPI + SQLite + pytest on the backend.

**Spec:** `docs/superpowers/specs/2026-08-02-ios-tab-navigation-design.md`

## Global Constraints

- Classification list, verbatim: `["children", "adults", "anabel", "asmr", "tv", "movies"]`. `adults` keeps its plural spelling; `education` no longer exists.
- The four Videos groups, in display order: `children`, `adults`, `anabel`, `asmr`. Display labels are `.capitalized` except ASMR, which is uppercased.
- Tab icons: Videos `play.rectangle.on.rectangle`, TV `tv`, Movies `film`.
- No new network requests for the group screen: no counts, no `/api/groups` endpoint, no prefetching of the four lists.
- Search (`.searchable`) stays attached to the video grid only; the group screen has no search field.
- The options menu (upload / autoplay / randomize / downloads / settings) and the toolbar are identical on every tab.
- Scroll-anchor keys stay `"grid:<filter>"` (`RestorationState.gridKey`) — unchanged.
- `DevLog.event` / `DevLog.error` only; never `print`.
- Backend tests: `python -m pytest tests/` from the repo root. Kit tests: `cd ios/PatataTubeKit && swift test`.

---

### Task 1: Backend — `asmr` classification

**Files:**
- Modify: `db.py:9`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `db.CLASSIFICATIONS == ["children", "adults", "anabel", "asmr", "tv", "movies"]`, served by `GET /api/classifications` and accepted by the classify endpoints.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_api.py`:

```python
def test_api_classifications_includes_asmr(client):
    resp = client.get("/api/classifications")
    assert resp.status_code == 200
    assert resp.json()["classifications"] == [
        "children", "adults", "anabel", "asmr", "tv", "movies"
    ]


def test_api_classify_accepts_asmr(client):
    video_id = _create_video(client)
    resp = client.post(
        f"/api/videos/{video_id}/classify",
        json={"classification": "asmr"},
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    assert resp.status_code == 200
    assert resp.json()["classification"] == "asmr"


def test_api_classify_still_rejects_unknown(client):
    video_id = _create_video(client)
    resp = client.post(
        f"/api/videos/{video_id}/classify",
        json={"classification": "not-a-real-one"},
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    assert resp.status_code == 400
```

Before writing these, read the top of `tests/test_api.py` and reuse whatever helper the existing classify tests use to create a row and to send the token (the names above, `_create_video` and `TOKEN`, are placeholders for those existing helpers — match the file, do not invent new ones). `test_api_videos_filters_by_classification` (line ~738) and `test_api_classifications_lists_all` (line ~759) show the established pattern.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "asmr or still_rejects" -v`
Expected: the two `asmr` tests FAIL (classifications list lacks `asmr`; classify returns 400), the rejection test PASSES.

- [ ] **Step 3: Add the classification**

`db.py:9`:

```python
CLASSIFICATIONS = ["children", "adults", "anabel", "asmr", "tv", "movies"]
```

That is the whole change: `router.py`, `services.py` and the SSR page all import this constant. No migration — `videos.classification` is free text validated at the edges, and no existing row changes.

- [ ] **Step 4: Run the full backend suite**

Run: `python -m pytest tests/ -q`
Expected: all pass. If a test asserts the old five-item list verbatim, update it to the new six-item list.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_api.py
git commit -m "feat: add asmr classification"
```

---

### Task 2: Kit — `MediaTab` + `Route.group` + restored tab

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift:9-13` (Route), `:31-55` (RestorationState)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaTabTests.swift` (create), `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationStoreTests.swift` (modify)

**Interfaces:**
- Consumes: `RestorationState`, `RestorationStore` (existing).
- Produces:
  - `public enum MediaTab: String, CaseIterable, Codable, Hashable, Sendable { case videos, tv, movies }`
  - `public static let MediaTab.videoGroups: [String]`
  - `public var MediaTab.filter: String?` (`videos` → `nil`, `tv` → `"tv"`, `movies` → `"movies"`)
  - `public static func MediaTab.label(forGroup: String) -> String`
  - `Route.group(name: String)`
  - `RestorationState.tab: MediaTab?` (nil means "not recorded" → callers treat as `.videos`), memberwise `init` gains `tab: MediaTab? = nil` as its **last** parameter.

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaTabTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class MediaTabTests: XCTestCase {
    func testGroupsAreTheFourVideoBuckets() {
        XCTAssertEqual(MediaTab.videoGroups, ["children", "adults", "anabel", "asmr"])
    }

    func testFilterPerTab() {
        XCTAssertNil(MediaTab.videos.filter)
        XCTAssertEqual(MediaTab.tv.filter, "tv")
        XCTAssertEqual(MediaTab.movies.filter, "movies")
    }

    func testLabelUppercasesASMRAndCapitalizesTheRest() {
        XCTAssertEqual(MediaTab.label(forGroup: "asmr"), "ASMR")
        XCTAssertEqual(MediaTab.label(forGroup: "children"), "Children")
        XCTAssertEqual(MediaTab.label(forGroup: "anabel"), "Anabel")
    }
}
```

Append to `RestorationStoreTests.swift` (inside the existing `final class RestorationStoreTests`, reusing its `makeDefaults()` helper):

```swift
    func testRoundTripsSelectedTab() {
        let defaults = makeDefaults()
        var state = RestorationState.empty
        state.tab = .movies
        state.path = [.group(name: "anabel")]
        RestorationStore(defaults: defaults).save(state)
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), state)
    }

    func testBlobWithoutTabStillDecodes() {
        let defaults = makeDefaults()
        // A blob written by a build that predates MediaTab: no "tab" key.
        let legacy = """
        {"filter":"children","path":[],"search":"","scrollAnchors":{}}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: RestorationStore.storageKey)
        let loaded = RestorationStore(defaults: defaults).load()
        XCTAssertNil(loaded.tab)
        XCTAssertEqual(loaded.filter, "children")
    }
```

Read `RestorationStore.swift` first: use its real storage-key symbol and its real save API in these tests (`storageKey` and `save(_:)` above are the expected names — if the type spells them differently, match the source; if the key is private, make it `internal static` so the test can reach it, since the package tests use `@testable import`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter "MediaTabTests|RestorationStoreTests"`
Expected: compile failure — `MediaTab` and `Route.group` do not exist.

- [ ] **Step 3: Add `MediaTab`**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift`:

```swift
import Foundation

/// The three top-level media types in the tab bar. `filter` maps a tab onto the
/// `VideoStore.filter` value it loads; the Videos tab has none of its own —
/// its filter is whichever group the user opened.
public enum MediaTab: String, CaseIterable, Codable, Hashable, Sendable {
    case videos
    case tv
    case movies

    /// The Videos tab's groups, in display order. These are classification
    /// values, so they must stay in sync with `CLASSIFICATIONS` in `db.py`.
    public static let videoGroups = ["children", "adults", "anabel", "asmr"]

    public var filter: String? {
        switch self {
        case .videos: return nil
        case .tv: return "tv"
        case .movies: return "movies"
        }
    }

    public static func label(forGroup group: String) -> String {
        group == "asmr" ? "ASMR" : group.capitalized
    }
}
```

- [ ] **Step 4: Add `Route.group` and `RestorationState.tab`**

`RestorationState.swift`, in the `Route` enum:

```swift
public enum Route: Codable, Hashable, Sendable {
    case group(name: String)   // classification value
    case show(title: String)   // ShowGroup.id
    case movie(id: Int)        // Video.id
    case downloads
}
```

In `RestorationState`, add the property next to `filter`:

```swift
    /// Which tab was on screen. Optional so blobs written before the tab bar
    /// existed still decode; `nil` is read as `.videos` by callers.
    public var tab: MediaTab?
```

Add `tab` to `.empty` (`tab: nil`) and to the memberwise `init` as the **last** parameter with a default:

```swift
    public static let empty = RestorationState(
        filter: nil, path: [], search: "", scrollAnchors: [:], player: nil, tab: nil
    )

    public init(filter: String?, path: [Route], search: String,
                scrollAnchors: [String: String], player: PlayerState?,
                tab: MediaTab? = nil) {
        self.filter = filter
        self.path = path
        self.search = search
        self.scrollAnchors = scrollAnchors
        self.player = player
        self.tab = tab
    }
```

Optional + synthesized `Codable` is what makes the legacy blob decode: `decodeIfPresent` is generated for optional properties, so a missing `"tab"` key is not an error. Do not write a custom `init(from:)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter "MediaTabTests|RestorationStoreTests"`
Expected: PASS. If `RestorationResolver` or other kit code now fails to compile on a non-exhaustive `switch` over `Route`, add a `case .group: ...` arm that behaves like `.downloads` (no video resolution) — the group route carries no id to resolve.

- [ ] **Step 6: Full kit build + test**

Run: `cd ios/PatataTubeKit && swift test --filter "MediaTabTests|RestorationStoreTests|RestorationResolverTests|RestorationApplyDecisionTests"`
Expected: PASS.

Note: a full parallel `swift test` run has pre-existing unrelated failures (see `CLAUDE.md`); filtered runs are the signal.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/MediaTab.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaTabTests.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationStoreTests.swift
git commit -m "feat(ios): add MediaTab, group route and restored tab"
```

---

### Task 3: Kit — `GroupPosterStore`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/GroupPosterStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupPosterStoreTests.swift`

**Interfaces:**
- Consumes: `Video` (`id: Int`, `previewUrl: String?`), `MediaTab.videoGroups`.
- Produces:
  - `public struct GroupPoster: Codable, Equatable, Sendable { public var videoID: Int; public var path: String }`
  - `public struct GroupPosterStore: Sendable`
    - `public init(defaults: UserDefaults = .standard)`
    - `public func poster(for group: String) -> GroupPoster?`
    - `public func record(_ videos: [Video], for group: String?)`
    - `public static func key(_ group: String) -> String` → `"groupPoster:<group>"`

Why a stored record rather than reading the live list: the group screen must show art for groups that are not currently loaded, and `VideoStore` only ever holds one classification's list. Why `videoID` is stored alongside the path: the existing preview disk cache is keyed by video id (`CacheManager.cachedPreviewURL(for:path:)`), so the card can render from disk with no request.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupPosterStoreTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class GroupPosterStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "groupposter.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func video(id: Int, preview: String?) -> Video {
        Video.fixture(id: id, previewUrl: preview)
    }

    func testUnknownGroupHasNoPoster() {
        let store = GroupPosterStore(defaults: makeDefaults())
        XCTAssertNil(store.poster(for: "asmr"))
    }

    func testRecordsFirstVideoWithAPreview() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 1, preview: nil), video(id: 2, preview: "/videos/2/preview")],
                     for: "children")
        XCTAssertEqual(store.poster(for: "children"),
                       GroupPoster(videoID: 2, path: "/videos/2/preview"))
    }

    func testEmptyListLeavesThePreviousPosterAlone() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 2, preview: "/videos/2/preview")], for: "children")
        store.record([], for: "children")
        XCTAssertEqual(store.poster(for: "children")?.videoID, 2)
    }

    func testIgnoresNonGroupFilters() {
        let store = GroupPosterStore(defaults: makeDefaults())
        store.record([video(id: 3, preview: "/videos/3/preview")], for: "tv")
        store.record([video(id: 4, preview: "/videos/4/preview")], for: nil)
        XCTAssertNil(store.poster(for: "tv"))
    }

    func testGroupsGetSeparateKeys() {
        XCTAssertNotEqual(GroupPosterStore.key("children"), GroupPosterStore.key("adults"))
    }
}
```

`Video.fixture(id:previewUrl:)` is a placeholder for however the existing kit tests build a `Video` — read `VideoTests.swift` or `VideoStoreTests.swift` and use that helper. If there is no shared helper, add a small private `makeVideo` inside this test file that fills every required `Video` field.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter GroupPosterStoreTests`
Expected: compile failure — `GroupPosterStore` does not exist.

- [ ] **Step 3: Implement the store**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/GroupPosterStore.swift`:

```swift
import Foundation

/// The art shown on one Videos-group card: the newest video in that group that
/// had a preview, last time the group was loaded.
public struct GroupPoster: Codable, Equatable, Sendable {
    public var videoID: Int
    public var path: String

    public init(videoID: Int, path: String) {
        self.videoID = videoID
        self.path = path
    }
}

/// Remembers one poster per Videos group so the group screen can render art for
/// groups that aren't loaded. Deliberately fed from lists that were fetched
/// anyway — the group screen itself issues no requests.
public struct GroupPosterStore: Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(_ group: String) -> String { "groupPoster:\(group)" }

    public func poster(for group: String) -> GroupPoster? {
        guard let data = defaults.data(forKey: Self.key(group)) else { return nil }
        return try? JSONDecoder().decode(GroupPoster.self, from: data)
    }

    /// Records the first video carrying a preview. The list arrives in the
    /// server's display order, so "first" is the same row the grid shows first.
    /// A group with no usable video keeps whatever it had — an empty fetch (or
    /// an offline one) must not blank a card that already has art.
    public func record(_ videos: [Video], for group: String?) {
        guard let group, MediaTab.videoGroups.contains(group) else { return }
        guard let match = videos.first(where: { $0.previewUrl?.isEmpty == false }),
              let path = match.previewUrl,
              let data = try? JSONEncoder().encode(GroupPoster(videoID: match.id, path: path))
        else { return }
        defaults.set(data, forKey: Self.key(group))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter GroupPosterStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/GroupPosterStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/GroupPosterStoreTests.swift
git commit -m "feat(ios): remember one poster per video group"
```

---

### Task 4: Kit — record posters when a group's list lands

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift` (init + `load()`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Consumes: `GroupPosterStore` from Task 3.
- Produces: `VideoStore.init` gains `groupPosters: GroupPosterStore? = nil` (last parameter, defaulted, so no existing call site changes). Every successful `load()` calls `groupPosters?.record(fetched, for: filter)`.

- [ ] **Step 1: Write the failing test**

Append to `VideoStoreTests.swift` (match the file's existing style for building a store with a stubbed `VideoAPI` — read a nearby test such as one covering `load()` and copy its setup):

```swift
    func testLoadRecordsTheGroupPoster() async {
        let defaults = UserDefaults(suiteName: "videostore.poster.\(UUID().uuidString)")!
        let posters = GroupPosterStore(defaults: defaults)
        let api = StubAPI(videos: [makeVideo(id: 7, previewUrl: "/videos/7/preview")])
        let store = VideoStore(api: api, defaults: defaults, groupPosters: posters)
        store.filter = "children"

        await store.load()

        XCTAssertEqual(posters.poster(for: "children"),
                       GroupPoster(videoID: 7, path: "/videos/7/preview"))
    }
```

`StubAPI` and `makeVideo` are placeholders for the file's existing stub API type and video factory — use the real names.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStoreTests.testLoadRecordsTheGroupPoster`
Expected: compile failure — `VideoStore.init` has no `groupPosters` parameter.

- [ ] **Step 3: Wire it in**

In `VideoStore`, add the stored property and init parameter:

```swift
    private let groupPosters: GroupPosterStore?
```

```swift
    public init(api: VideoAPI, cache: VideoListCaching? = nil,
                mediaCache: MediaCaching? = nil,
                positionStore: ResumePositionStore? = nil,
                defaults: UserDefaults = .standard,
                groupPosters: GroupPosterStore? = nil) {
        ...
        self.groupPosters = groupPosters
        self.filter = defaults.string(forKey: Self.filterKey) ?? "children"
    }
```

In `load()`, inside the `if generation == loadGeneration { ... }` block that applies `fetched` (i.e. only for a fetch that was not superseded), add:

```swift
                groupPosters?.record(fetched, for: filter)
```

Placing it inside the generation guard matters: a stale slower fetch must not overwrite a newer group's poster, the same reason it must not overwrite `videos`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStoreTests`
Expected: the new test PASSES. Re-run any failure filtered on its own name before treating it as a regression (`VideoStoreTests` has known parallel-run flakiness).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
git commit -m "feat(ios): record group poster on every list load"
```

---

### Task 5: App — `GroupsView`

**Files:**
- Create: `ios/PatataTube/Sources/GroupsView.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift` (construct `GroupPosterStore`, pass to `VideoStore`)
- Reference: `ios/PatataTube/Sources/ShowsView.swift` (the layout being mirrored)

**Interfaces:**
- Consumes: `MediaTab.videoGroups`, `MediaTab.label(forGroup:)`, `GroupPosterStore`, `Route.group(name:)`, `AuthedImage`, `AppModel.cache.cachedPreviewURL(for:path:)`.
- Produces: `struct GroupsView: View` with `init(posters: GroupPosterStore)`; `AppModel.groupPosters: GroupPosterStore`.

- [ ] **Step 1: Create the view**

There is no automated iOS UI test target, so this task is verified by building and by the manual checklist in Task 7 — no failing-test step.

Create `ios/PatataTube/Sources/GroupsView.swift`:

```swift
// ios/PatataTube/Sources/GroupsView.swift
import SwiftUI
import PatataTubeKit

/// Root of the Videos tab: one poster card per group, laid out exactly like
/// `ShowsView`'s show cards. Tapping pushes that group's grid.
///
/// Issues no requests: art comes from `GroupPosterStore` (written whenever a
/// group's list was fetched anyway) plus the preview disk cache, so a group
/// never opened on this device simply shows a placeholder tile.
struct GroupsView: View {
    let posters: GroupPosterStore
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(MediaTab.videoGroups, id: \.self) { group in
                NavigationLink(value: Route.group(name: group)) {
                    VStack(alignment: .leading, spacing: 6) {
                        artwork(for: group)
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background(.secondary.opacity(0.2))
                            .cornerRadius(8)
                            .clipped()
                        Text(MediaTab.label(forGroup: group))
                            .font(.subheadline).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .id(group)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func artwork(for group: String) -> some View {
        if let poster = posters.poster(for: group) {
            AuthedImage(
                path: poster.path,
                localFileURL: model.cache.cachedPreviewURL(for: poster.videoID, path: poster.path)
            )
        } else {
            // No spinner: nothing is loading, there is simply nothing recorded yet.
            Color.clear.overlay(
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
        }
    }
}
```

- [ ] **Step 2: Give `AppModel` the poster store**

In `AppModel.swift`, add the property and pass it to the `VideoStore` it constructs:

```swift
    let groupPosters = GroupPosterStore()
```

```swift
        VideoStore(api: ..., cache: ..., mediaCache: ..., positionStore: ...,
                   groupPosters: groupPosters)
```

Match the surrounding construction call exactly — only the new argument is added, as the last one.

- [ ] **Step 3: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build`

(If that simulator name is not installed, run `xcrun simctl list devicetypes` and substitute an available iPad.)
Expected: BUILD SUCCEEDED. `GroupsView` is not referenced yet — that is Task 6.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/GroupsView.swift ios/PatataTube/Sources/AppModel.swift
git commit -m "feat(ios): add Videos group screen"
```

---

### Task 6: App — `RootTabView`, per-tab stacks, group route, restoration

This is the task that changes navigation. It is one task because a half-applied version does not run: deleting `filterTabs` without the tab bar leaves no way to change classification.

**Files:**
- Create: `ios/PatataTube/Sources/RootTabView.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (add `tab` parameter, root content switch, `destination(for:)`, `initialLoad`, delete `filterTabs`, restoration write)
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift` (root view becomes `RootTabView`)

**Interfaces:**
- Consumes: `MediaTab`, `Route.group`, `GroupsView`, `RestorationState.tab`, `VideoStore.switchFilter(to:)`, `AppModel.restorationGate`, `AppModel.restorationStore`.
- Produces: `struct RootTabView: View`; `VideoGridView.init(tab: MediaTab)`.

- [ ] **Step 1: Add the `tab` parameter and switch the root content on it**

In `VideoGridView`, add above the `@EnvironmentObject`s:

```swift
    /// Which tab this instance is the content of. Fixed for the lifetime of the
    /// view — `RootTabView` builds one instance per tab.
    let tab: MediaTab
```

Replace the root-content chain in `body` (currently `if store.filter == "tv" { ShowsView(...) } else if store.filter == "movies" { moviesGrid } else { defaultGrid }`) with a switch on `tab`:

```swift
                    if store.isLoading && filteredVideos.isEmpty && tab != .videos {
                        SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                                     showsTextBars: tab == .tv)
                    } else {
                        switch tab {
                        case .videos:
                            GroupsView(posters: model.groupPosters)
                        case .tv:
                            ShowsView(
                                videos: filteredVideos,
                                onPlay: { video, queue in
                                    play(video, queueSnapshot: queue, caller: "shows")
                                },
                                onDownload: { await download($0) },
                                onItemAppear: { gridItemAppeared($0) },
                                onItemDisappear: { gridItemDisappeared($0) }
                            )
                        case .movies:
                            moviesGrid
                        }
                    }
```

The Videos tab's root never shows a skeleton: it renders four static cards and triggers no load.

- [ ] **Step 2: Add the `.group` destination**

In `destination(for:)`, add the case (the grid it pushes is the existing `defaultGrid`, plus the skeleton state that used to live at the root):

```swift
        case .group:
            ScrollView {
                if store.isLoading && filteredVideos.isEmpty {
                    SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0)
                } else {
                    defaultGrid
                }
            }
```

Extend `RestorationTracking.describe` with the new case so nav logging stays complete:

```swift
            case .group(let name): return "group(\(name))"
```

- [ ] **Step 3: Delete the picker**

Remove the `filterTabs` computed property and the `ToolbarItem(placement: .principal) { filterTabs }` entry. Remove the now-unused `@State private var classifications` **only if** nothing else reads it — `VideoCell(classifications:)` does, so keep the state and its `api.classifications()` assignment in `initialLoad`, but fix its stale default:

```swift
    @State private var classifications: [String] = ["children", "adults", "anabel", "asmr", "tv", "movies"]
```

Attach the search field only where it belongs. `.searchable` currently sits on the `NavigationStack`'s content, which now includes the group screen; move it so it applies to the pushed grid instead. Concretely: keep `.searchable(text: $searchText, prompt: "Search videos")` on the root content for `.tv` and `.movies`, and for `.videos` apply it inside the `.group` destination in Step 2 (attach it to that `ScrollView`). The `onChange(of: searchText)` debounce stays where it is — it is view-wide state, not a modifier on the field.

- [ ] **Step 4: Record the tab, and gate restoration to the restored tab**

In the `RestorationTracking` modifier (the `onChange`/`mutate` block that writes `filter` and `path`), also write the tab. Pass `tab` into `restorationTracking(...)` alongside `filter`, and store it:

```swift
                    model.restorationStore.mutate {
                        $0.tab = tab
                        // ...existing filter/path/search writes unchanged
                    }
```

In `initialLoad`, make the three instances cooperate. `model.restorationGate.claim()` already allows exactly one caller per launch, and the tab that should claim it is the restored one:

```swift
    private func initialLoad(scrollProxy: ScrollViewProxy) async {
        let restoredTab = model.restorationStore.load().tab ?? .videos
        guard tab == restoredTab else {
            DevLog.event(.nav, "initial load skipped", ["reason": "other tab", "tab": tab.rawValue])
            return
        }
        guard model.restorationGate.claim() else {
            DevLog.event(.nav, "initial load skipped", ["reason": "already restored"])
            return
        }
        ...
```

The rest of `initialLoad` is unchanged, except that the Videos tab must not `bootLoad()` while sitting on the group screen with nothing selected. Guard the load and the path application:

```swift
        let restored = model.restorationStore.load()
        // Videos tab restored at its root has no classification to fetch.
        let restoredGroup: String? = {
            if case .group(let name)? = restored.path.first { return name }
            return nil
        }()
        if tab == .videos {
            if let restoredGroup {
                await store.switchFilter(to: restoredGroup)
            }
        } else {
            if store.filter != tab.filter {
                await store.switchFilter(to: tab.filter)
            } else {
                await store.bootLoad()
            }
        }
```

Everything after that (search text, `RestorationResolver.resolve`, `applyPath`, player, scroll anchor, `MemoryProbe.snapshot`) stays exactly as it is. A restored path of `[.group("anabel"), .show("Bluey")]` therefore replays whole: the group is loaded before the path is applied, so the show route resolves.

- [ ] **Step 5: Write `RootTabView`**

Create `ios/PatataTube/Sources/RootTabView.swift`:

```swift
// ios/PatataTube/Sources/RootTabView.swift
import SwiftUI
import PatataTubeKit

/// The app's root: three media types, each with its own navigation stack.
///
/// `VideoStore.filter` is still the one source of truth for what is loaded, so
/// selecting a tab does exactly what the old segmented picker did — it calls
/// `switchFilter`. The Videos tab is the exception: its root is a group screen
/// that loads nothing, so it only switches the filter when a group is already
/// open beneath it.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore
    @State private var selection: MediaTab = .videos

    var body: some View {
        TabView(selection: $selection) {
            VideoGridView(tab: .videos)
                .tabItem { Label("Videos", systemImage: "play.rectangle.on.rectangle") }
                .tag(MediaTab.videos)
            VideoGridView(tab: .tv)
                .tabItem { Label("TV", systemImage: "tv") }
                .tag(MediaTab.tv)
            VideoGridView(tab: .movies)
                .tabItem { Label("Movies", systemImage: "film") }
                .tag(MediaTab.movies)
        }
        .onAppear {
            selection = model.restorationStore.load().tab ?? .videos
        }
        .onChange(of: selection) { _, newValue in
            DevLog.event(.nav, "tab selected", ["tab": newValue.rawValue])
            model.restorationStore.mutate { $0.tab = newValue }
            guard let filter = newValue.filter, store.filter != filter else { return }
            Task { await store.switchFilter(to: filter) }
        }
    }
}
```

Selecting the Videos tab deliberately does not switch the filter: its root shows no videos, and tapping a group is what sets the filter (Step 6).

- [ ] **Step 6: Make the group tap switch the filter**

The `NavigationLink(value:)` in `GroupsView` pushes without side effects, so the filter must follow the pushed route. In `VideoGridView`, add to `body` (next to the other `onChange` handlers):

```swift
            .onChange(of: path) { _, newPath in
                guard tab == .videos else { return }
                guard case .group(let name)? = newPath.first else { return }
                guard store.filter != name else { return }
                Task { await store.switchFilter(to: name) }
            }
```

Driving it off `path` rather than the tap means a restored path and a hand tap take the same code path, and popping back to the group screen leaves the last group loaded (harmless — the group screen reads no videos).

- [ ] **Step 7: Swap the root view**

In `PatataTubeApp.swift`, replace `VideoGridView()` in the `WindowGroup` with `RootTabView()`, keeping every `.environmentObject` and modifier already attached to it.

- [ ] **Step 8: Build and run in the simulator**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build`
Expected: BUILD SUCCEEDED.

Then launch it (Xcode Run, or `xcrun simctl`) against a running `./serve`, and confirm by hand:
1. Three tabs appear; Videos opens on four cards.
2. Tapping Children shows the grid that used to be behind the picker.
3. TV shows the show grid; a show opens its episodes. Movies shows movie posters.
4. The old segmented control is gone from every tab.
5. `grep '"kind":"nav"' log/ios.jsonl | tail -20` shows `tab selected` and no `show route unresolved`.

- [ ] **Step 9: Commit**

```bash
git add ios/PatataTube/Sources/RootTabView.swift \
        ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Sources/PatataTubeApp.swift
git commit -m "feat(ios): replace classification picker with media tabs"
```

---

### Task 7: Restoration check + docs

**Files:**
- Modify: `ios/README.md` (manual checklist)
- Modify: `CLAUDE.md` (iOS section)

- [ ] **Step 1: Verify restoration by hand**

With the app running against `./serve`:

1. Videos → Adults → scroll a few rows down. Background the app (Cmd+Shift+H), force-quit it, relaunch.
   Expected: Videos tab, Adults grid pushed, roughly the same scroll position.
2. TV → open a show → force-quit → relaunch.
   Expected: TV tab, that show's episodes on screen.
3. Movies tab → force-quit → relaunch. Expected: Movies tab at its root.
4. Delete and reinstall the app (clears UserDefaults, simulating a blob without `tab`), relaunch.
   Expected: Videos tab, group screen, no crash — this is the legacy-decode path from Task 2.

If (1) lands on the group screen instead of the grid, the restored `path` was not applied: check `grep 'initial load applying' log/ios.jsonl` for `apply_path=false`.

- [ ] **Step 2: Update the manual checklist**

In `ios/README.md`, add to the checklist:

```markdown
- [ ] Tab bar shows Videos / TV / Movies; Videos opens on the four group cards
      (Children, Adults, Anabel, ASMR) and ASMR is empty until something is
      classified into it.
- [ ] Tapping a group opens that group's grid; search only appears there, not on
      the group screen.
- [ ] Force-quit inside a group (and inside a show under TV) and relaunch: the
      app returns to that screen with its scroll position.
- [ ] A group never opened on this device shows a placeholder tile, not a
      spinner; after visiting it once, its card shows the newest video's
      preview.
```

- [ ] **Step 3: Update CLAUDE.md**

In the `### iOS` section, add a bullet:

```markdown
- **Navigation is a `TabView` over `MediaTab` (videos/tv/movies).** `RootTabView`
  builds one `VideoGridView` per tab, each with its own `NavigationStack`;
  `VideoStore.filter` is still the single source of what's loaded, and tab
  selection calls `switchFilter` the way the old toolbar picker did. The Videos
  tab's root is `GroupsView` — four classification cards (children, adults,
  anabel, asmr) that fetch nothing; their art comes from `GroupPosterStore`, a
  UserDefaults record of each group's newest `preview_url` written by
  `VideoStore.load()`. Tapping a card pushes `Route.group(name:)`, and the
  `path` change is what sets the filter, so a hand tap and a restored path take
  the same code path.
```

- [ ] **Step 4: Commit**

```bash
git add ios/README.md CLAUDE.md
git commit -m "docs: record tab navigation and video groups"
```

---

## Verification

- `python -m pytest tests/ -q` — all pass.
- `cd ios/PatataTubeKit && swift test --filter "MediaTabTests|GroupPosterStoreTests|RestorationStoreTests|RestorationResolverTests|VideoStoreTests"` — all pass.
- `cd ios/PatataTubeKit && swift test -c release --filter "MediaTabTests|GroupPosterStoreTests"` — passes (no `DevLog` changes here, but release config stays green).
- App builds and the Task 6 Step 8 + Task 7 Step 1 manual walkthroughs behave as described.

## Out of scope

Group counts, a `/api/groups` endpoint, prefetching the four lists, cross-group search, and any change to the grid, player, download or promote paths.
