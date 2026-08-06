# Grid List Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One step below the current 120pt cell-size floor renders a single-column list of rows instead of a grid of tiny cards, in both `cellSize`-driven grids.

**Architecture:** A pure `GridDisplayMode` type in PatataTubeKit owns the whole size/mode state machine (which mode a stored `cellSize` means, what the smaller/bigger menu buttons target, their labels, their disabled state) and is unit-tested. `VideoGridView` reads it to pick its `columns` and to branch each of its two split-out grid properties between the existing cards (`VideoCell`, `MovieCell`) and new flat rows (`VideoRow`, `MovieRow`). The enclosing `ScrollView`, scroll-anchor restore, search, and `.refreshable` are deliberately untouched.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM local package `PatataTubeKit`, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-03-grid-list-mode-design.md`

## Global Constraints

- Cell sizes: floor `120`, ceiling `420`, step `50`, list sentinel `70`. These exact numbers.
- Menu labels, exact strings: `"Smaller cells"`, `"Bigger cells"`, `"List view"`, `"Grid view"`.
- Row thumbnail box: exactly `78`pt wide × `44`pt tall, for both video and movie rows.
- `AppModel`, the `gridCellSizes` UserDefaults key, `Feed`, `Video`, the backend, and `project.yml` must not change. XcodeGen globs `ios/PatataTube/Sources/**`, so new app files need no project edit.
- No new iOS app test target. All automated tests live in `ios/PatataTubeKit/Tests/PatataTubeKitTests/`.
- Out of scope, do not touch: `GroupsView`, `ShowsView`, `EpisodesView`, `DownloadsView`.
- The `ScrollView` / `ScrollViewReader` / `.refreshable` / `.searchable` structure in `VideoGridView` must not be restructured. Pull-to-refresh must behave identically in list mode.
- New PatataTubeKit tests use XCTest (mirroring `ResumeDecisionTests.swift`), not swift-testing.
- Existing kit tests are flaky under a full parallel run (documented in `CLAUDE.md`). Verify new tests with a filtered run.

---

## File Structure

| File | Responsibility |
|---|---|
| `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift` (new) | Pure mode/step state machine. No SwiftUI. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift` (new) | Unit tests for the above. |
| `ios/PatataTube/Sources/VideoRow.swift` (new) | One list row for a `defaultGrid` video: thumb, title, ellipsis menu. |
| `ios/PatataTube/Sources/MovieRow.swift` (new) | One list row for a movie: thumb, title, navigation link. |
| `ios/PatataTube/Sources/VideoGridView.swift` (modify) | Mode-driven `columns`; branch `defaultGrid` and `moviesGrid`; menu buttons driven by `GridDisplayMode`. |
| `ios/PatataTube/Sources/SkeletonGrid.swift` (modify) | Row-shaped placeholders when in list mode. |

---

### Task 1: `GridDisplayMode` in PatataTubeKit

The pure state machine. Nothing renders yet; this task ends with green unit tests.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces, all `public`, used by Task 2:
  - `enum GridDisplayMode: Equatable, Sendable { case list; case grid(cellSize: Double) }`
  - `GridDisplayMode.minCellSize: Double` = 120, `.maxCellSize: Double` = 420, `.step: Double` = 50, `.listCellSize: Double` = 70
  - `static func forCellSize(_ size: Double) -> GridDisplayMode`
  - `static func smaller(from size: Double) -> GridSizeStep?` — `nil` means the button is disabled
  - `static func bigger(from size: Double) -> GridSizeStep?` — `nil` means the button is disabled
  - `struct GridSizeStep: Equatable, Sendable { let title: String; let systemImage: String; let target: Double }`

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class GridDisplayModeTests: XCTestCase {
    func testSentinelIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(70), .list)
    }

    func testAnythingBelowTheFloorIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(119), .list)
    }

    func testTheFloorIsStillAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(120), .grid(cellSize: 120))
    }

    func testCeilingIsAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(420), .grid(cellSize: 420))
    }

    func testSmallerFromTheFloorOffersListView() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 120),
                       GridSizeStep(title: "List view",
                                    systemImage: "list.bullet",
                                    target: 70))
    }

    func testSmallerAboveTheFloorStepsDown() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 170),
                       GridSizeStep(title: "Smaller cells",
                                    systemImage: "minus.magnifyingglass",
                                    target: 120))
    }

    func testSmallerClampsToTheFloor() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 150)?.target, 120)
    }

    func testSmallerIsDisabledInList() {
        XCTAssertNil(GridDisplayMode.smaller(from: 70))
    }

    func testBiggerFromListReturnsToTheGrid() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 70),
                       GridSizeStep(title: "Grid view",
                                    systemImage: "square.grid.2x2",
                                    target: 120))
    }

    func testBiggerStepsUp() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 120),
                       GridSizeStep(title: "Bigger cells",
                                    systemImage: "plus.magnifyingglass",
                                    target: 170))
    }

    func testBiggerClampsToTheCeiling() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 400)?.target, 420)
    }

    func testBiggerIsDisabledAtTheCeiling() {
        XCTAssertNil(GridDisplayMode.bigger(from: 420))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ios/PatataTubeKit && swift test --filter GridDisplayModeTests
```

Expected: compile failure — `cannot find 'GridDisplayMode' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift`:

```swift
import Foundation

/// One step of the grid's size control: what the button says and what it sets.
/// `nil` from `smaller`/`bigger` is the disabled state.
public struct GridSizeStep: Equatable, Sendable {
    public let title: String
    public let systemImage: String
    public let target: Double

    public init(title: String, systemImage: String, target: Double) {
        self.title = title
        self.systemImage = systemImage
        self.target = target
    }
}

/// How a feed's stored `cellSize` should render.
///
/// The size is one persisted number per feed (`AppModel.cellSize(for:)`), so
/// list mode is a sentinel below the grid floor rather than a second stored
/// flag: nothing about persistence or migration changes, and an older build
/// reading the sentinel just draws 70pt cells.
public enum GridDisplayMode: Equatable, Sendable {
    case list
    case grid(cellSize: Double)

    public static let minCellSize: Double = 120
    public static let maxCellSize: Double = 420
    public static let step: Double = 50
    /// One step below `minCellSize`. Any value under the floor reads as list.
    public static let listCellSize: Double = 70

    public static func forCellSize(_ size: Double) -> GridDisplayMode {
        size < minCellSize ? .list : .grid(cellSize: size)
    }

    public static func smaller(from size: Double) -> GridSizeStep? {
        switch forCellSize(size) {
        case .list:
            return nil
        case .grid(let size) where size <= minCellSize:
            return GridSizeStep(title: "List view",
                                systemImage: "list.bullet",
                                target: listCellSize)
        case .grid(let size):
            return GridSizeStep(title: "Smaller cells",
                                systemImage: "minus.magnifyingglass",
                                target: max(size - step, minCellSize))
        }
    }

    public static func bigger(from size: Double) -> GridSizeStep? {
        switch forCellSize(size) {
        case .list:
            return GridSizeStep(title: "Grid view",
                                systemImage: "square.grid.2x2",
                                target: minCellSize)
        case .grid(let size) where size >= maxCellSize:
            return nil
        case .grid(let size):
            return GridSizeStep(title: "Bigger cells",
                                systemImage: "plus.magnifyingglass",
                                target: min(size + step, maxCellSize))
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ios/PatataTubeKit && swift test --filter GridDisplayModeTests
```

Expected: 12 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/GridDisplayMode.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/GridDisplayModeTests.swift
git commit -m "feat(ios): add GridDisplayMode size/mode state machine"
```

---

### Task 2: Wire the mode into `VideoGridView`'s columns and menu

After this task the app already reaches list mode — as a single column of the
existing cards. The rows land in Tasks 3 and 4. This is an intentional
intermediate: it is independently runnable and it isolates the state-machine
wiring from the row views.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` — the size constants (~207-209), `columns` (~236-238), the two size buttons in `optionsMenu` (~511-519)

**Interfaces:**
- Consumes: `GridDisplayMode`, `GridSizeStep` from Task 1.
- Produces, for Tasks 3-5: a `private var displayMode: GridDisplayMode` computed on `VideoGridView`.

- [ ] **Step 1: Replace the local size constants with a mode accessor**

`PatataTubeKit` is already imported by this file. Delete these three lines
(currently at `VideoGridView.swift:207-209`):

```swift
    private let minCellSize: Double = 120
    private let maxCellSize: Double = 420
    private let cellSizeStep: Double = 50
```

and put this immediately after `private var cellSize: Double { … }`:

```swift
    /// List or grid, derived from the one persisted per-feed size.
    private var displayMode: GridDisplayMode { GridDisplayMode.forCellSize(cellSize) }
```

- [ ] **Step 2: Make `columns` mode-driven**

Replace `columns` (currently `VideoGridView.swift:236-238`):

```swift
    private var columns: [GridItem] {
        switch displayMode {
        case .list:
            return [GridItem(.flexible(), spacing: 0)]
        case .grid(let size):
            return [GridItem(.adaptive(minimum: size), spacing: 16)]
        }
    }
```

- [ ] **Step 3: Drive the two menu buttons from the mode**

Replace the two size buttons in `optionsMenu` (currently
`VideoGridView.swift:511-519`) with:

```swift
            let smallerStep = GridDisplayMode.smaller(from: cellSize)
            Button {
                if let smallerStep { model.setCellSize(smallerStep.target, for: store.feed) }
            } label: {
                Label(smallerStep?.title ?? "Smaller cells",
                      systemImage: smallerStep?.systemImage ?? "minus.magnifyingglass")
            }
            .disabled(smallerStep == nil)

            let biggerStep = GridDisplayMode.bigger(from: cellSize)
            Button {
                if let biggerStep { model.setCellSize(biggerStep.target, for: store.feed) }
            } label: {
                Label(biggerStep?.title ?? "Bigger cells",
                      systemImage: biggerStep?.systemImage ?? "plus.magnifyingglass")
            }
            .disabled(biggerStep == nil)
```

- [ ] **Step 4: Confirm nothing else referenced the deleted constants**

```bash
grep -n "minCellSize\|maxCellSize\|cellSizeStep" ios/PatataTube/Sources/VideoGridView.swift
```

Expected: no matches (the `GridDisplayMode.` static ones live in the package, not here). If anything matches, it is a leftover call site — convert it to the mode.

- [ ] **Step 5: Build and run**

```bash
cd ios/PatataTube && xcodegen generate
```

Then build and run in Xcode (iPad simulator). Manually verify:
- open a group, shrink cells to the floor — the smaller button reads **"List view"**
- tap it — a single column of full-width cards appears, smaller button now disabled
- the bigger button reads **"Grid view"**; tapping it returns to 120pt cells
- the Movies tab has its own independent size — shrinking there does not change the group's

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): drive grid columns and size menu from GridDisplayMode"
```

---

### Task 3: `VideoRow` and the `defaultGrid` branch

**Files:**
- Create: `ios/PatataTube/Sources/VideoRow.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` — `defaultGrid` (~431-465)

**Interfaces:**
- Consumes: `displayMode` from Task 2; `CacheState` (`.notCached` / `.downloading(Double)` / `.cached`), `AuthedImage(path:localFileURL:fill:onNetworkLoad:)`, `VideoInfoView(video:groups:cacheState:cachedPreviewURL:localFileURL:)`, `View.logTap(_:_:)` — all existing.
- Produces: `VideoRow`, taking exactly the same stored properties as `VideoCell` (`video`, `cacheState`, `currentCacheState`, `cachedPreviewURL`, `onPreviewLoaded`, `localFileURL`, `groups`, `onPlay`, `onPlaySleep`, `onDownload`, `onCancel`, `onDeleteCache`, `onSetGroup`, `onPromote`, `onChooseVersion`, `onDelete`) so the call site passes an identical argument list to either.

- [ ] **Step 1: Write `VideoRow`**

Create `ios/PatataTube/Sources/VideoRow.swift`:

```swift
// ios/PatataTube/Sources/VideoRow.swift
import SwiftUI
import PatataTubeKit

/// One video as a flat list row — the shape `defaultGrid` takes at its
/// densest setting, where a 120pt card is too small to read.
///
/// Everything left of the ellipsis plays. Every control the card carries in
/// its footer (download, version picker, play-and-sleep, server status) moves
/// into the menu, so the row itself is a thumbnail and a title. A download in
/// flight is therefore invisible until the menu is opened, and the percentage
/// in the label is a snapshot from when it opened — menus don't live-update.
/// That is the accepted trade for a clean row; the grid still shows progress.
struct VideoRow: View {
    let video: Video
    let cacheState: CacheState
    let currentCacheState: @Sendable () -> CacheState
    var cachedPreviewURL: URL? = nil
    var onPreviewLoaded: ((Data) -> Void)? = nil
    var localFileURL: URL? = nil
    let groups: [VideoGroup]
    let onPlay: () -> Void
    let onPlaySleep: () -> Void
    let onDownload: () async -> Bool
    let onCancel: () -> Void
    let onDeleteCache: () -> Void
    let onSetGroup: (Int) -> Void
    let onPromote: (PlexKind) -> Void
    let onChooseVersion: (Int) -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var showingInfo = false
    @State private var downloading = false

    static let thumbWidth: CGFloat = 78
    static let thumbHeight: CGFloat = 44

    private var isChildrenVideo: Bool {
        groups.first { $0.id == video.groupID }?.name == "children" && video.status == "done"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onPlay) {
                    HStack(spacing: 12) {
                        thumbnail
                        Text(video.title ?? video.url)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .logTap("play", ["video_id": "\(video.id)", "status": video.status])

                menu
            }
            .padding(.vertical, 6)

            Divider()
        }
        .confirmationDialog("Delete this video?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingInfo) {
            VideoInfoView(video: video, groups: groups, cacheState: cacheState,
                          cachedPreviewURL: cachedPreviewURL, localFileURL: localFileURL)
        }
    }

    /// Fixed 78x44 box for both aspect ratios, so titles line up across feeds.
    /// Plex posters are 2:3 and letterbox inside it rather than centre-cropping.
    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil || cachedPreviewURL != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                    fill: !video.isPlexItem,
                                    onNetworkLoad: onPreviewLoaded)
                    }
                    .clipped()
            }
        }
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipped()
        .cornerRadius(4)
    }

    private var menu: some View {
        Menu {
            downloadActions

            if isChildrenVideo {
                Button("Play and sleep", systemImage: "moon.fill") { onPlaySleep() }
            }

            Button("Info", systemImage: "info.circle") { showingInfo = true }

            if !video.isPlexItem {
                ForEach(groups) { group in
                    Button(group.label) { onSetGroup(group.id) }
                }
                Section("Move to Plex") {
                    ForEach(PlexKind.allCases, id: \.self) { kind in
                        Button(kind == .tv ? "TV" : "Movies") { onPromote(kind) }
                    }
                }
            }

            if video.versions.count > 1 {
                Section("Version") {
                    ForEach(video.versions) { version in
                        let chosen = version.id == (video.chosenVersionId ?? video.versions.first?.id)
                        Button {
                            onChooseVersion(version.id)
                        } label: {
                            if chosen {
                                Label(version.label ?? "Version \(version.id)",
                                      systemImage: "checkmark")
                            } else {
                                Text(version.label ?? "Version \(version.id)")
                            }
                        }
                    }
                }
            }

            if video.status != "done" {
                Button("Status: \(video.status)") {}.disabled(true)
            }

            Divider()
            Button("Delete video", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var downloadActions: some View {
        switch cacheState {
        case .notCached:
            Button("Download", systemImage: "arrow.down.circle") {
                guard !downloading else { return }
                downloading = true
                Task {
                    _ = await onDownload()
                    downloading = false
                }
            }
            .disabled(downloading)
        case .downloading(let progress):
            Button("Downloading \(Int(progress * 100))%") {}.disabled(true)
            Button("Cancel download", systemImage: "xmark.circle") { onCancel() }
        case .cached:
            Button("Delete download", systemImage: "trash") { onDeleteCache() }
        }
    }
}
```

- [ ] **Step 2: Verify the `CacheState` cases actually match**

```bash
grep -n "enum CacheState" -A 8 ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
grep -n "case cached\|case notCached\|case downloading" ios/PatataTube/Sources/VideoCell.swift ios/PatataTube/Sources/DownloadButton.swift
```

Expected: three cases, `.notCached`, `.downloading(Double)`, `.cached`. If the payload shape differs from `Double`, adjust the `downloadActions` switch to match — do not change `CacheState`.

- [ ] **Step 3: Branch `defaultGrid` on the mode**

In `VideoGridView.swift`, wrap the cell construction inside `defaultGrid`'s
`ForEach`. Keep `.id(...)`, `.onAppear`, `.onDisappear` on the *outside* of the
branch so scroll-anchor restore is untouched. The body becomes:

```swift
    private var defaultGrid: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(filteredVideos) { video in
                let cache = model.cache
                let videoId = video.id
                let versionId = video.chosenVersionId
                Group {
                    if case .list = displayMode {
                        VideoRow(
                            video: video,
                            cacheState: cache.state(for: videoId, versionId: versionId),
                            currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl),
                            onPreviewLoaded: { data in
                                guard let path = video.previewUrl,
                                      cache.cachedPreviewURL(for: videoId, path: path) == nil else { return }
                                cache.storePreview(data, for: videoId, path: path)
                            },
                            localFileURL: cache.localURL(for: videoId, versionId: versionId),
                            groups: groups.groups,
                            onPlay: { play(video, caller: "grid-row") },
                            onPlaySleep: { play(video, sleepMode: true, caller: "grid-row-sleep") },
                            onDownload: { await download(video) },
                            onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                            onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) },
                            onSetGroup: { groupID in Task { await store.setGroup(id: video.id, groupID: groupID) } },
                            onPromote: { kind in Task { await store.promote(id: video.id, kind: kind) } },
                            onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                            onDelete: { Task { await store.delete(id: video.id) } }
                        )
                    } else {
                        VideoCell(
                            video: video,
                            cacheState: cache.state(for: videoId, versionId: versionId),
                            currentCacheState: { cache.state(for: videoId, versionId: versionId) },
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl),
                            onPreviewLoaded: { data in
                                guard let path = video.previewUrl,
                                      cache.cachedPreviewURL(for: videoId, path: path) == nil else { return }
                                cache.storePreview(data, for: videoId, path: path)
                            },
                            localFileURL: cache.localURL(for: videoId, versionId: versionId),
                            groups: groups.groups,
                            onPlay: { play(video, caller: "grid-cell") },
                            onPlaySleep: { play(video, sleepMode: true, caller: "grid-cell-sleep") },
                            onDownload: { await download(video) },
                            onCancel: { cache.cancel(id: videoId, versionId: versionId) },
                            onDeleteCache: { cache.removeCached(id: videoId, versionId: versionId) },
                            onSetGroup: { groupID in Task { await store.setGroup(id: video.id, groupID: groupID) } },
                            onPromote: { kind in Task { await store.promote(id: video.id, kind: kind) } },
                            onChooseVersion: { versionId in Task { await store.chooseVersion(id: video.id, versionId: versionId) } },
                            onDelete: { Task { await store.delete(id: video.id) } }
                        )
                    }
                }
                .id(String(videoId))
                .onAppear { gridItemAppeared(String(videoId)) }
                .onDisappear { gridItemDisappeared(String(videoId)) }
            }
        }
        .padding()
    }
```

Add `gridSpacing` next to `displayMode`:

```swift
    /// Rows carry their own divider and sit flush; cards keep the 16pt gutter.
    private var gridSpacing: CGFloat {
        if case .list = displayMode { return 0 }
        return 16
    }
```

- [ ] **Step 4: Build and check the type checker did not blow up**

```bash
cd ios/PatataTube && xcodegen generate
```

Build in Xcode. Expected: builds clean. If the compiler reports
"unable to type-check this expression in reasonable time" on `defaultGrid`,
split the two branches into two `private func` members
(`videoRow(for:)` / `videoCell(for:)`) returning `some View` and call those
from the `Group` — that is the established remedy in this file.

- [ ] **Step 5: Manual verification**

In a group's list mode, check:
- rows show thumbnail + one-line title + ellipsis, separated by hairlines
- tapping anywhere left of the ellipsis starts playback
- the menu shows Download / Cancel download + "Downloading N%" / Delete download matching the video's actual cache state
- Info opens the inspector; group items move the video; Move to Plex works; Delete asks first
- pull-to-refresh still refreshes
- typing in search still filters the rows
- background the app on a scrolled position, relaunch, and confirm the list restores to the same video

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoRow.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): render videos as rows in list mode"
```

---

### Task 4: `MovieRow` and the `moviesGrid` branch

**Files:**
- Create: `ios/PatataTube/Sources/MovieRow.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` — `moviesGrid` (~416-429)

**Interfaces:**
- Consumes: `displayMode` and `gridSpacing` from Tasks 2-3; `Route.movie(id:)`; `AppModel` from the environment (same as `MovieCell`).
- Produces: `MovieRow(video:cachedPreviewURL:)` — same two properties `MovieCell` takes.

- [ ] **Step 1: Write `MovieRow`**

Create `ios/PatataTube/Sources/MovieRow.swift`:

```swift
// ios/PatataTube/Sources/MovieRow.swift
import SwiftUI
import PatataTubeKit

/// One movie as a flat list row. Like `MovieCell` it is only a link — no menu
/// and no download control, because `MovieDetailView` owns those. The poster
/// letterboxes inside the same 78x44 box `VideoRow` uses so titles line up
/// across feeds.
struct MovieRow: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    var cachedPreviewURL: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: Route.movie(id: video.id)) {
                HStack(spacing: 12) {
                    thumbnail
                    Text(video.title ?? video.url)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(.black)
            if video.previewUrl != nil || cachedPreviewURL != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl, localFileURL: cachedPreviewURL,
                                    fill: false,
                                    onNetworkLoad: { data in
                                        guard let path = video.previewUrl,
                                              model.cache.cachedPreviewURL(for: video.id, path: path) == nil else { return }
                                        model.cache.storePreview(data, for: video.id, path: path)
                                    })
                    }
                    .clipped()
            }
        }
        .frame(width: VideoRow.thumbWidth, height: VideoRow.thumbHeight)
        .clipped()
        .cornerRadius(4)
    }
}
```

- [ ] **Step 2: Branch `moviesGrid` on the mode**

Replace `moviesGrid` in `VideoGridView.swift`:

```swift
    private var moviesGrid: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(filteredVideos) { video in
                Group {
                    if case .list = displayMode {
                        MovieRow(
                            video: video,
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                        )
                    } else {
                        MovieCell(
                            video: video,
                            cachedPreviewURL: model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
                        )
                    }
                }
                .id(String(video.id))
                .onAppear { gridItemAppeared(String(video.id)) }
                .onDisappear { gridItemDisappeared(String(video.id)) }
            }
        }
        .padding()
    }
```

- [ ] **Step 3: Build**

```bash
cd ios/PatataTube && xcodegen generate
```

Build in Xcode. Expected: clean.

- [ ] **Step 4: Manual verification**

On the Movies tab:
- shrink to "List view" — poster rows appear, posters letterboxed in the 78pt box, titles aligned with the video rows in a group
- tapping a row pushes `MovieDetailView`
- pull-to-refresh and search still work
- the Videos tab's own size is unaffected

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/MovieRow.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): render movies as rows in list mode"
```

---

### Task 5: List-shaped loading skeleton

**Files:**
- Modify: `ios/PatataTube/Sources/SkeletonGrid.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` — the two `SkeletonGrid` call sites (~373 in `rootScrollView`, ~542 in the `.group` destination)

**Interfaces:**
- Consumes: `displayMode` from Task 2; `VideoRow.thumbWidth` / `.thumbHeight` from Task 3.
- Produces: `SkeletonGrid(columns:aspectRatio:showsTextBars:count:isList:)` — `isList` defaults to `false`, so no other call site changes.

- [ ] **Step 1: Add the list variant to `SkeletonGrid`**

In `SkeletonGrid.swift`, add the property next to `count`:

```swift
    /// Rows instead of cards, matching `VideoRow`'s geometry, so the
    /// placeholder does not change shape the moment real content lands.
    var isList: Bool = false
```

and replace the `body` with:

```swift
    var body: some View {
        LazyVGrid(columns: columns, spacing: isList ? 0 : 16) {
            ForEach(0..<count, id: \.self) { _ in
                if isList {
                    listRow
                } else {
                    card
                }
            }
        }
        .padding()
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }

    private var card: some View {
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

    private var listRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: VideoRow.thumbWidth, height: VideoRow.thumbHeight)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 80, height: 10)
                }
                Spacer(minLength: 44)
            }
            .padding(.vertical, 6)
            Divider()
        }
    }
```

- [ ] **Step 2: Pass the mode at both call sites**

In `rootScrollView` (~line 373):

```swift
                SkeletonGrid(columns: columns, aspectRatio: 2.0/3.0,
                             showsTextBars: tab == .tv,
                             isList: displayMode == .list)
```

In the `.group` destination (~line 542):

```swift
                        SkeletonGrid(columns: columns, aspectRatio: 16.0/9.0,
                                     isList: displayMode == .list)
```

`GridDisplayMode` is `Equatable`, so `== .list` compiles. `showsTextBars` keeps
its position before `isList` because it is declared first on the struct.

- [ ] **Step 3: Build**

```bash
cd ios/PatataTube && xcodegen generate
```

Build in Xcode. Expected: clean.

- [ ] **Step 4: Manual verification**

Force a cold load (delete the app's cached list or launch with the server
stopped then started) while a feed is in list mode. Expected: the placeholder
is rows of grey thumb + two bars, not squares, and it does not reflow when the
real rows arrive.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/SkeletonGrid.swift ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): row-shaped loading skeleton in list mode"
```

---

### Task 6: Full verification pass

**Files:** none modified.

- [ ] **Step 1: Run the package suite, filtered**

```bash
cd ios/PatataTubeKit && swift build && swift test --filter GridDisplayModeTests
```

Expected: build succeeds, 12 tests pass.

- [ ] **Step 2: Run the full package suite for regressions**

```bash
cd ios/PatataTubeKit && swift test
```

Known pre-existing noise, documented in `CLAUDE.md`: a `Fatal error: Index out
of range` from the swift-testing suites and occasional `VideoStoreTests`
flakiness under the parallel run. Re-run any failure filtered before treating
it as a regression. Nothing in this change touches those types.

- [ ] **Step 3: Walk the manual checklist**

Against a running backend, in both a group feed and the Movies tab:

| Check | Expected |
|---|---|
| Shrink to floor | button reads "List view" |
| Tap it | rows appear; smaller button disabled |
| Bigger button | reads "Grid view", returns to 120pt cards |
| Per-feed | each feed's mode is independent and survives relaunch |
| Tap a video row | plays |
| Tap a movie row | pushes the detail view |
| Row menu | download/cancel/delete-download match cache state |
| Row menu | Info, groups, Move to Plex, versions, status line, Delete |
| Pull-to-refresh | works in list mode, both feeds |
| Search | filters rows |
| Scroll restore | relaunch returns to the same item |

- [ ] **Step 4: Commit anything outstanding**

```bash
git status --short
```

Expected: clean.

---

## Self-Review Notes

Spec coverage: mode + sentinel + labels → Task 1-2; columns and grid branches →
Tasks 2-4; `VideoRow` contents including the accepted invisible-progress trade →
Task 3; `MovieRow` including the shared 78pt thumb box → Task 4; skeleton →
Task 5; tests and the manual checklist → Tasks 1 and 6. The spec's untouched
list (`AppModel`, backend, `Video`, `project.yml`, the four out-of-scope views)
appears in Global Constraints. No task depends on a type it does not define or
consume from a named earlier task.
