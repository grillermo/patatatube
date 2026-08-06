# iOS State Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reopening the iPad app returns to the exact screen, scroll position, search query and video the user left, with the player paused at its resume point.

**Architecture:** A `Codable` `RestorationState` blob in `UserDefaults` (package-side, `RestorationStore`) records the classification tab, an id-only navigation path, per-screen scroll anchors, the search text and any in-progress playback. `VideoGridView`'s implicit `NavigationStack` converts to an explicit `NavigationStack(path:)` over a `Route` enum, so pushes are describable and replayable. All resolution logic — turning a persisted blob plus a loaded video list into a validated path and a playable queue — is a pure function, `RestorationResolver.resolve`, so it is unit-testable without a running app.

**Tech Stack:** Swift 6, SwiftUI, iOS 17 deployment target, XCTest, SwiftPM local package (`ios/PatataTubeKit`), XcodeGen app target (`ios/PatataTube`).

**Spec:** `docs/superpowers/specs/2026-08-02-ios-state-restoration-design.md`

## Global Constraints

- Deployment target is **iOS 17** (`ios/PatataTube/project.yml`, `ios/PatataTubeKit/Package.swift`). Do not use iOS 18+ API. In particular `.scrollPosition(id:)` does not cover `List` on iOS 17 — use `ScrollViewReader`.
- All logic that can live in `ios/PatataTubeKit` **must** live there. It is the only testable half; the app target has no test target.
- Tests are XCTest (`final class XTests: XCTestCase`), in `ios/PatataTubeKit/Tests/PatataTubeKitTests/`.
- Package tests run with `cd ios/PatataTubeKit && swift test`. A full parallel run has known pre-existing failures (a `Fatal error: Index out of range` from the swift-testing suites, occasional `VideoStoreTests` flakes) — always confirm a failure with a **filtered** run before treating it as a regression.
- Never use `print` in app or package code. Use `DevLog.event` / `DevLog.error`.
- Restoration must never throw into the UI. Unreadable or undecodable storage is treated as "no state" and overwritten, exactly like `WebHistoryStore`.
- No expiry, no TTL. State restores no matter how old.
- `UserDefaults` key for the blob: `restorationState`.

---

### Task 1: `RestorationState` model and `RestorationStore`

The persisted shape and its `UserDefaults` wrapper. Nothing consumes it yet.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum Route: Codable, Hashable, Sendable` with cases `.show(title: String)`, `.movie(id: Int)`, `.downloads`
  - `public struct PlayerState: Codable, Equatable, Sendable` with `videoID: Int`, `versionID: Int?`, `sleepMode: Bool`
  - `public struct RestorationState: Codable, Equatable, Sendable` with `filter: String?`, `path: [Route]`, `search: String`, `scrollAnchors: [String: String]`, `player: PlayerState?`, plus `public static let empty`
  - `public static func RestorationState.gridKey(filter: String?) -> String` and `public static func RestorationState.showKey(title: String) -> String`
  - `public final class RestorationStore: @unchecked Sendable` with `public static let storageKey = "restorationState"`, `public init(defaults: UserDefaults = .standard)`, `public func load() -> RestorationState`, `public func save(_ state: RestorationState)`, `public func mutate(_ body: (inout RestorationState) -> Void)`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationStoreTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class RestorationStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "restoration.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLoadWithNothingStoredReturnsEmpty() {
        let store = RestorationStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), RestorationState.empty)
    }

    func testRoundTripsEveryField() {
        let defaults = makeDefaults()
        var state = RestorationState.empty
        state.filter = "tv"
        state.path = [.show(title: "The Bear"), .movie(id: 42), .downloads]
        state.search = "bear"
        state.scrollAnchors = [
            RestorationState.gridKey(filter: "tv"): "show:The Bear",
            RestorationState.showKey(title: "The Bear"): "12",
        ]
        state.player = PlayerState(videoID: 42, versionID: 7, sleepMode: true)

        RestorationStore(defaults: defaults).save(state)

        // A fresh instance reads what the first one wrote.
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), state)
    }

    func testCorruptStorageLoadsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: RestorationStore.storageKey)

        let store = RestorationStore(defaults: defaults)
        XCTAssertEqual(store.load(), RestorationState.empty)

        // And is overwritten by the next save rather than blocking it.
        var state = RestorationState.empty
        state.search = "kids"
        store.save(state)
        XCTAssertEqual(RestorationStore(defaults: defaults).load(), state)
    }

    func testMutateAppliesToStoredState() {
        let defaults = makeDefaults()
        let store = RestorationStore(defaults: defaults)
        store.mutate { $0.path = [.downloads] }
        store.mutate { $0.search = "abc" }

        let loaded = RestorationStore(defaults: defaults).load()
        XCTAssertEqual(loaded.path, [.downloads])
        XCTAssertEqual(loaded.search, "abc")
    }

    func testScreenKeysAreDistinct() {
        XCTAssertNotEqual(RestorationState.gridKey(filter: "tv"),
                          RestorationState.gridKey(filter: "movies"))
        XCTAssertNotEqual(RestorationState.gridKey(filter: nil),
                          RestorationState.gridKey(filter: "tv"))
        XCTAssertNotEqual(RestorationState.showKey(title: "The Bear"),
                          RestorationState.gridKey(filter: "The Bear"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationStoreTests`
Expected: FAIL — `cannot find 'RestorationStore' in scope`.

- [ ] **Step 3: Write the model**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift`:

```swift
import Foundation

/// One pushed screen in the grid's navigation stack.
///
/// Routes carry **ids, not values**: never a `Video` or a `ShowGroup`. The row
/// is looked up against the loaded list at render time, so a route that no
/// longer resolves (deleted video, renamed show) can be dropped instead of
/// decoding into a phantom screen. It also keeps the persisted blob small.
public enum Route: Codable, Hashable, Sendable {
    case show(title: String)   // ShowGroup.id
    case movie(id: Int)        // Video.id
    case downloads
}

/// Playback that was on screen when the app went away. The queue is not
/// persisted — it is rebuilt at launch from the restored screen — and the
/// position is not either: `ResumePositionStore` already owns that.
public struct PlayerState: Codable, Equatable, Sendable {
    public var videoID: Int
    public var versionID: Int?
    public var sleepMode: Bool

    public init(videoID: Int, versionID: Int?, sleepMode: Bool) {
        self.videoID = videoID
        self.versionID = versionID
        self.sleepMode = sleepMode
    }
}

/// Everything needed to put the user back where they left off.
public struct RestorationState: Codable, Equatable, Sendable {
    /// Recorded for a self-describing blob and to scope scroll anchors. **Not**
    /// applied at boot: `VideoStore` already persists the selected
    /// classification itself under `selectedClassification`.
    public var filter: String?
    /// Root-first.
    public var path: [Route]
    /// The committed search text (`activeSearch`), not the in-flight field.
    public var search: String
    /// Screen key -> id of the topmost visible item on that screen.
    public var scrollAnchors: [String: String]
    public var player: PlayerState?

    public static let empty = RestorationState(
        filter: nil, path: [], search: "", scrollAnchors: [:], player: nil
    )

    public init(filter: String?, path: [Route], search: String,
                scrollAnchors: [String: String], player: PlayerState?) {
        self.filter = filter
        self.path = path
        self.search = search
        self.scrollAnchors = scrollAnchors
        self.player = player
    }

    /// Scroll-anchor key for the root grid on one classification tab.
    public static func gridKey(filter: String?) -> String {
        "grid:\(filter ?? "")"
    }

    /// Scroll-anchor key for one show's episode list.
    public static func showKey(title: String) -> String {
        "show:\(title)"
    }
}
```

- [ ] **Step 4: Write the store**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationStore.swift`:

```swift
import Foundation

/// `UserDefaults`-backed home for `RestorationState`, in the shape of
/// `WebHistoryStore`: nothing throws, and unreadable storage is treated as no
/// state and overwritten on the next save. A broken blob must never keep the
/// app from launching or from recording fresh state.
///
/// There is deliberately no expiry — a relaunch a week later still restores.
public final class RestorationStore: @unchecked Sendable {
    public static let storageKey = "restorationState"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RestorationState {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public func save(_ state: RestorationState) {
        lock.lock(); defer { lock.unlock() }
        saveLocked(state)
    }

    /// Read-modify-write under one lock, so two edits landing in the same run
    /// loop tick cannot clobber each other.
    public func mutate(_ body: (inout RestorationState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = loadLocked()
        body(&state)
        saveLocked(state)
    }

    private func loadLocked() -> RestorationState {
        guard let data = defaults.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(RestorationState.self, from: data)
        else { return .empty }
        return state
    }

    private func saveLocked(_ state: RestorationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationStoreTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RestorationState.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/RestorationStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationStoreTests.swift
git commit -m "feat(ios): persist restoration state"
```

---

### Task 2: `VisibleItemsTracker`

Computes the topmost visible item id from `onAppear` / `onDisappear` callbacks. SwiftUI delivers these out of order and can report a disappear after the next appear, so the tracker holds a set and derives the answer from the current ordering rather than trusting call order.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/VisibleItemsTracker.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VisibleItemsTrackerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@MainActor public final class VisibleItemsTracker` with `public init()`, `public func setOrder(_ ids: [String])`, `public func appeared(_ id: String)`, `public func disappeared(_ id: String)`, `public var topmost: String? { get }`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/VisibleItemsTrackerTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

@MainActor
final class VisibleItemsTrackerTests: XCTestCase {
    func testTopmostIsEarliestInOrder() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c", "d"])
        tracker.appeared("c")
        tracker.appeared("b")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testDisappearingTheTopItemAdvancesTopmost() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.disappeared("a")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testDisappearAfterLaterAppearStillTracks() {
        // SwiftUI can deliver the outgoing cell's disappear after the incoming
        // cell's appear; order of callbacks must not decide the answer.
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.appeared("c")
        tracker.disappeared("b")
        tracker.disappeared("a")
        XCTAssertEqual(tracker.topmost, "c")
    }

    func testNothingVisibleIsNil() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b"])
        tracker.appeared("a")
        tracker.disappeared("a")
        XCTAssertNil(tracker.topmost)
    }

    func testIdsNotInOrderAreIgnored() {
        // A cell from the previous tab can report a disappear after the list
        // has already been replaced.
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b"])
        tracker.appeared("zz")
        XCTAssertNil(tracker.topmost)
        tracker.appeared("b")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testSetOrderDropsVisibleIdsThatVanished() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.setOrder(["b", "c"])   // "a" deleted from the list
        XCTAssertEqual(tracker.topmost, "b")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter VisibleItemsTrackerTests`
Expected: FAIL — `cannot find 'VisibleItemsTracker' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/VisibleItemsTracker.swift`:

```swift
import Foundation

/// Tracks which cells are on screen and reports the topmost one, for scroll
/// restoration.
///
/// Callbacks arrive out of order — SwiftUI routinely delivers the outgoing
/// cell's `onDisappear` after the incoming cell's `onAppear` — so nothing here
/// depends on call order. Visibility is a set; "topmost" is derived from the
/// list's current ordering, which is also what makes the answer survive
/// insertions, deletions and cell-size changes.
@MainActor
public final class VisibleItemsTracker {
    private var order: [String] = []
    private var indexByID: [String: Int] = [:]
    private var visible: Set<String> = []

    public init() {}

    /// The list's current ordering. Ids no longer present stop counting as
    /// visible, so a deleted row cannot pin the anchor forever.
    public func setOrder(_ ids: [String]) {
        order = ids
        indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        visible = visible.filter { indexByID[$0] != nil }
    }

    public func appeared(_ id: String) {
        guard indexByID[id] != nil else { return }
        visible.insert(id)
    }

    public func disappeared(_ id: String) {
        visible.remove(id)
    }

    /// The visible id earliest in the current ordering, or nil when nothing is
    /// on screen.
    public var topmost: String? {
        visible.min { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter VisibleItemsTrackerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/VisibleItemsTracker.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/VisibleItemsTrackerTests.swift
git commit -m "feat(ios): track topmost visible cell for scroll restore"
```

---

### Task 3: `RestorationResolver`

The pure boot step: persisted blob + loaded videos → a validated path and a playable queue. This is the whole reason restoration is testable; keep every rule here and none of it in the view.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationResolver.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationResolverTests.swift`

**Interfaces:**
- Consumes: `Route`, `PlayerState`, `RestorationState` (Task 1); `Video`, `ShowGroup` (existing).
- Produces:
  - `public struct ResolvedPlayer: Equatable, Sendable` with `video: Video`, `queue: [Video]`, `sleepMode: Bool`
  - `public struct ResolvedRestoration: Equatable, Sendable` with `path: [Route]`, `search: String`, `player: ResolvedPlayer?`
  - `public enum RestorationResolver` with
    `public static func resolve(state: RestorationState, videos: [Video], hasPendingQuickAction: Bool) -> ResolvedRestoration`

Rules, all covered by the tests below:

1. `videos` is the **already-searched** list (the view applies `state.search` before calling), so show and movie resolution see exactly what the user will see.
2. A route that does not resolve is dropped **along with every route after it** — a movie pushed from inside a deleted show is unreachable.
3. `.downloads` always resolves; it depends on no row.
4. The player's queue is that show's episodes when the deepest `.show` route survives, otherwise the whole list.
5. The player is dropped when its video is not in that queue.
6. A pending quick action suppresses the player entirely; the path still restores.

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationResolverTests.swift`:

```swift
import XCTest
@testable import PatataTubeKit

final class RestorationResolverTests: XCTestCase {
    private func episode(_ id: Int, show: String, season: Int, ep: Int) -> Video {
        Video(id: id, url: "/x", title: "E\(ep)", platform: nil, sourceKey: nil,
              previewUrl: nil, classification: "tv", position: id, status: "done",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: show, season: season, episode: ep,
              summary: nil, showPreviewUrl: nil)
    }

    private func movie(_ id: Int) -> Video {
        Video(id: id, url: "/x", title: "M\(id)", platform: nil, sourceKey: nil,
              previewUrl: nil, classification: "movies", position: id, status: "done",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: nil, season: nil, episode: nil,
              summary: nil, showPreviewUrl: nil)
    }

    private func state(path: [Route], player: PlayerState? = nil,
                       search: String = "") -> RestorationState {
        RestorationState(filter: "tv", path: path, search: search,
                         scrollAnchors: [:], player: player)
    }

    func testResolvesShowAndMovieRoutes() {
        let videos = [episode(1, show: "The Bear", season: 1, ep: 1), movie(9)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear")]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.show(title: "The Bear")])

        let movieResolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 9)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(movieResolved.path, [.movie(id: 9)])
    }

    func testDownloadsRouteAlwaysResolves() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [.downloads]), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.downloads])
    }

    func testDroppedShowTruncatesEverythingAfterIt() {
        let videos = [movie(9)]   // the show is gone
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear"), .movie(id: 9)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [])
    }

    func testDroppedMovieIsRemoved() {
        let videos = [episode(1, show: "The Bear", season: 1, ep: 1)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear"), .movie(id: 404)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.show(title: "The Bear")])
    }

    func testPlayerQueueComesFromTheRestoredShow() {
        let videos = [
            episode(1, show: "The Bear", season: 1, ep: 1),
            episode(2, show: "The Bear", season: 1, ep: 2),
            movie(9),
        ]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear")],
                         player: PlayerState(videoID: 2, versionID: nil, sleepMode: false)),
            videos: videos, hasPendingQuickAction: false)

        XCTAssertEqual(resolved.player?.video.id, 2)
        XCTAssertEqual(resolved.player?.queue.map(\.id), [1, 2])
        XCTAssertEqual(resolved.player?.sleepMode, false)
    }

    func testPlayerQueueIsTheWholeListWithoutAShowRoute() {
        let videos = [movie(9), movie(10)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 10)],
                         player: PlayerState(videoID: 10, versionID: nil, sleepMode: true)),
            videos: videos, hasPendingQuickAction: false)

        XCTAssertEqual(resolved.player?.queue.map(\.id), [9, 10])
        XCTAssertEqual(resolved.player?.sleepMode, true)
    }

    func testPlayerDroppedWhenItsVideoIsGone() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], player: PlayerState(videoID: 404, versionID: nil, sleepMode: false)),
            videos: [movie(9)], hasPendingQuickAction: false)
        XCTAssertNil(resolved.player)
    }

    func testPendingQuickActionSuppressesPlayerButKeepsPath() {
        let videos = [movie(9)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 9)],
                         player: PlayerState(videoID: 9, versionID: nil, sleepMode: false)),
            videos: videos, hasPendingQuickAction: true)
        XCTAssertNil(resolved.player)
        XCTAssertEqual(resolved.path, [.movie(id: 9)])
    }

    func testSearchIsPassedThrough() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], search: "bear"), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.search, "bear")
    }

    func testEmptyStateResolvesToNothing() {
        let resolved = RestorationResolver.resolve(
            state: .empty, videos: [movie(9)], hasPendingQuickAction: false)
        XCTAssertEqual(resolved, ResolvedRestoration(path: [], search: "", player: nil))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationResolverTests`
Expected: FAIL — `cannot find 'RestorationResolver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/PatataTubeKit/Sources/PatataTubeKit/RestorationResolver.swift`:

```swift
import Foundation

/// Playback to reopen at launch, already matched against the loaded list.
public struct ResolvedPlayer: Equatable, Sendable {
    public var video: Video
    public var queue: [Video]
    public var sleepMode: Bool

    public init(video: Video, queue: [Video], sleepMode: Bool) {
        self.video = video
        self.queue = queue
        self.sleepMode = sleepMode
    }
}

public struct ResolvedRestoration: Equatable, Sendable {
    public var path: [Route]
    public var search: String
    public var player: ResolvedPlayer?

    public init(path: [Route], search: String, player: ResolvedPlayer?) {
        self.path = path
        self.search = search
        self.player = player
    }
}

/// Turns a persisted `RestorationState` plus the loaded video list into
/// something the grid can apply directly.
///
/// Pure by design: the app target has no test coverage, so every restoration
/// rule that could be wrong lives here where `swift test` can reach it.
public enum RestorationResolver {
    public static func resolve(
        state: RestorationState,
        videos: [Video],
        hasPendingQuickAction: Bool
    ) -> ResolvedRestoration {
        let shows = ShowGroup.group(videos)
        var path: [Route] = []

        // A route that no longer resolves takes the rest of the stack with it:
        // whatever was pushed from inside it is unreachable now.
        for route in state.path {
            switch route {
            case .show(let title):
                guard shows.contains(where: { $0.id == title }) else {
                    return finish(path: path, state: state, videos: videos,
                                  shows: shows, hasPendingQuickAction: hasPendingQuickAction)
                }
            case .movie(let id):
                guard videos.contains(where: { $0.id == id }) else {
                    return finish(path: path, state: state, videos: videos,
                                  shows: shows, hasPendingQuickAction: hasPendingQuickAction)
                }
            case .downloads:
                break   // depends on no row
            }
            path.append(route)
        }

        return finish(path: path, state: state, videos: videos,
                      shows: shows, hasPendingQuickAction: hasPendingQuickAction)
    }

    private static func finish(
        path: [Route],
        state: RestorationState,
        videos: [Video],
        shows: [ShowGroup],
        hasPendingQuickAction: Bool
    ) -> ResolvedRestoration {
        ResolvedRestoration(
            path: path,
            search: state.search,
            player: hasPendingQuickAction
                // An explicit launch intent outranks the previous session.
                ? nil
                : resolvePlayer(state.player, path: path, videos: videos, shows: shows)
        )
    }

    private static func resolvePlayer(
        _ player: PlayerState?,
        path: [Route],
        videos: [Video],
        shows: [ShowGroup]
    ) -> ResolvedPlayer? {
        guard let player else { return nil }

        // The queue is rebuilt, never persisted: whatever list the restored
        // screen shows is the list the player queues over.
        var queue = videos
        for case .show(let title) in path.reversed() {
            if let show = shows.first(where: { $0.id == title }) {
                queue = show.episodes
            }
            break
        }

        guard let video = queue.first(where: { $0.id == player.videoID }) else { return nil }
        return ResolvedPlayer(video: video, queue: queue, sleepMode: player.sleepMode)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter RestorationResolverTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RestorationResolver.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RestorationResolverTests.swift
git commit -m "feat(ios): resolve persisted restoration against loaded videos"
```

---

### Task 4: `startPaused` in the player

Restoration reopens the player **paused** at the resume point. Do this before wiring restoration so the boot path has the flag to pass.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift`
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift` (`VideoPlayerView` properties + `init`, `playWhenReady` at ~line 337)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (the `.fullScreenCover(item: $playing)` at ~line 250)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PlaybackQueue.startPaused: Bool` (new trailing parameter, defaults `false`), `VideoPlayerView.init(videos:startIndex:sleepMode:randomize:startSecs:startPaused:)`.

- [ ] **Step 1: Write the failing test**

Append to `ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift` (inside the existing test class):

```swift
    func testStartPausedDefaultsToFalseAndRoundTrips() {
        let video = Video(id: 1, url: "/x", title: "A", platform: nil, sourceKey: nil,
                          previewUrl: nil, classification: "movies", position: 1,
                          status: "done", errorMsg: nil, streamPath: "/videos/1/stream",
                          source: "library", showTitle: nil, season: nil, episode: nil,
                          summary: nil, showPreviewUrl: nil)

        XCTAssertFalse(PlaybackQueue(video: video, queueSnapshot: [video]).startPaused)
        XCTAssertTrue(
            PlaybackQueue(video: video, queueSnapshot: [video],
                          startSecs: 30, startPaused: true).startPaused
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackQueueTests`
Expected: FAIL — `value of type 'PlaybackQueue' has no member 'startPaused'`.

- [ ] **Step 3: Add the property**

In `PlaybackQueue.swift`, add the stored property after `startSecs` and the parameter at the end of `init`:

```swift
    /// Restoration only: mount seeked to `startSecs` but do not start playing.
    /// A relaunch must never produce surprise audio.
    public let startPaused: Bool
```

```swift
    public init(
        video: Video,
        queueSnapshot: [Video],
        sleepMode: Bool = false,
        startSecs: Double = 0,
        startPaused: Bool = false
    ) {
        self.sleepMode = sleepMode
        self.startSecs = startSecs
        self.startPaused = startPaused
        // ...rest unchanged
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter PlaybackQueueTests`
Expected: PASS.

- [ ] **Step 5: Thread the flag through the player**

In `VideoPlayerView.swift`, add the property next to `startSecs`:

```swift
    /// Restoration only: seek to `startSecs`, then wait for a tap instead of
    /// playing. Applies to the first item only — auto-advance always plays.
    let startPaused: Bool
```

Extend `init` (keep every existing parameter and default):

```swift
    init(videos: [Video], startIndex: Int, sleepMode: Bool = false,
         randomize: Bool = false, startSecs: Double = 0, startPaused: Bool = false) {
        self.videos = videos
        self.startIndex = startIndex
        self.sleepMode = sleepMode
        self.randomize = randomize
        self.startSecs = startSecs
        self.startPaused = startPaused
        _currentIndex = State(initialValue: startIndex)
        _sleepAfterCurrent = State(initialValue: sleepMode)
        _orientationLock = StateObject(wrappedValue: OrientationLockCoordinator())
    }
```

Add the suppression state next to the other `@State` properties:

```swift
    /// Cleared after the first item mounts, so only the restored item starts
    /// paused; every later item in the queue plays as usual.
    @State private var suppressAutoplayOnce: Bool = false
```

Seed it in `init`, right after `_sleepAfterCurrent`:

```swift
        _suppressAutoplayOnce = State(initialValue: startPaused)
```

In `playWhenReady` (~line 337), gate the two `player.play()` calls inside
`markReady` on the flag. Replace the body of `markReady`'s play step:

```swift
        let markReady = { (trigger: String) in
            guard self.player === player, !self.itemReady else { return }
            self.itemReady = true
            DevLog.event(.play, "mounted and playing", [
                "video_id": "\(self.video.id)", "trigger": trigger,
                "paused": "\(self.suppressAutoplayOnce)",
            ])
            if self.suppressAutoplayOnce {
                // Restored session: mounted and seeked, waiting for a tap.
                self.suppressAutoplayOnce = false
            } else {
                player.play()
            }
            self.readyObserver?.invalidate()
            self.readyObserver = nil
            self.readyTimeoutTask?.cancel()
            self.readyTimeoutTask = nil
        }
```

- [ ] **Step 6: Pass it at the presentation site**

In `VideoGridView.swift`, in `.fullScreenCover(item: $playing)`:

```swift
            .fullScreenCover(item: $playing) { request in
                VideoPlayerView(videos: request.videos, startIndex: request.startIndex,
                                sleepMode: request.sleepMode,
                                randomize: model.randomize(for: store.filter),
                                startSecs: request.startSecs,
                                startPaused: request.startPaused)
            }
```

- [ ] **Step 7: Build the app target**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/PlaybackQueue.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/PlaybackQueueTests.swift \
        ios/PatataTube/Sources/VideoPlayerView.swift \
        ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): allow the player to mount paused at a resume point"
```

---

### Task 5: Route-driven navigation stack

The invasive change, and the one with no automated coverage — verify by hand. Nothing is persisted yet; this task only makes the stack describable.

**Why `.downloads` must convert too:** SwiftUI does not support mixing a `navigationDestination(isPresented:)` with a `NavigationStack(path:)`. Leaving it desyncs the stack.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (~lines 103–170, 250s)
- Modify: `ios/PatataTube/Sources/ShowsView.swift`
- Modify: `ios/PatataTube/Sources/MovieCell.swift:15`
- Modify: `ios/PatataTube/Sources/EpisodesView.swift` (`EpisodesDownloadAllState.showDownloads`)

**Interfaces:**
- Consumes: `Route` (Task 1).
- Produces: `VideoGridView.path: [Route]` state; `ShowsView` and `EpisodesView` no longer own destinations.

- [ ] **Step 1: Add the path binding**

In `VideoGridView.swift`, next to the other `@State`:

```swift
    /// Explicit navigation path. Required for restoration — an implicit stack
    /// cannot be replayed — and the reason `.downloads` is a route rather than
    /// an `isPresented` destination: SwiftUI desyncs a stack that mixes the two.
    @State private var path: [Route] = []
```

Change `NavigationStack {` (~line 103) to `NavigationStack(path: $path) {`.

- [ ] **Step 2: Replace the three destinations with one**

Delete `.navigationDestination(for: Video.self) { ... }` and
`.navigationDestination(isPresented: $showDownloads) { ... }` from
`VideoGridView`, and delete
`.navigationDestination(for: ShowGroup.self) { ... }` from `ShowsView`. Add to
`VideoGridView`, in the same position the `Video` destination occupied:

```swift
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .show(let title):
                    // Resolved late, against the list actually on screen: a
                    // route holds only an id, so a renamed or deleted show
                    // resolves to nothing instead of a phantom screen.
                    if let show = ShowGroup.group(filteredVideos).first(where: { $0.id == title }) {
                        EpisodesView(show: show,
                                     onPlay: { video, queue in play(video, queueSnapshot: queue) },
                                     onDownload: { await download($0) },
                                     showDownloads: { path.append(.downloads) })
                    }
                case .movie(let id):
                    if let video = store.videos.first(where: { $0.id == id }) {
                        MovieDetailView(video: video,
                                        onPlay: { play($0) },
                                        onDownload: { await download($0) })
                    }
                case .downloads:
                    DownloadsView(
                        active: { model.cache.activeDownloads() },
                        recent: { model.cache.recentDownloads() },
                        video: { id, versionID in
                            Self.downloadVideo(id: id, versionID: versionID, videos: store.videos)
                        },
                        onCancel: { activity in
                            model.cache.cancel(id: activity.videoID, versionId: activity.versionID)
                        },
                        onPlay: { video in play(video) }
                    )
                }
            }
```

(Keep the `onCancel` argument labels exactly as they are in the current
`DownloadsView` call site — copy them across rather than retyping.)

- [ ] **Step 3: Convert the link values**

`ShowsView.swift`: `NavigationLink(value: show)` becomes
`NavigationLink(value: Route.show(title: show.title))`. `ShowsView` keeps its
`onPlay`/`onDownload` parameters — it just no longer declares a destination.

`MovieCell.swift:15`: `NavigationLink(value: video)` becomes
`NavigationLink(value: Route.movie(id: video.id))`.

- [ ] **Step 4: Convert the Downloads pushes**

In `VideoGridView.swift`, delete `@State private var showDownloads = false` and
replace its one use in the Download-all confirm button:

```swift
                Button("Download") {
                    let targets = request.targets
                    pendingDownloadAll = nil
                    // Push Downloads so the confirm lands on the progress list.
                    path.append(.downloads)
                    Task { await runDownloadAll(targets) }
                }
```

In `EpisodesView.swift`, delete `var showDownloads = false` from
`EpisodesDownloadAllState` and its `navigationDestination`/presentation use.
Add a closure property to `EpisodesView` instead, defaulted so existing
previews/callers keep compiling:

```swift
    /// Pushing Downloads belongs to the stack's owner — this view no longer
    /// declares destinations.
    var showDownloads: () -> Void = {}
```

Replace each `downloadState.showDownloads = true` with `showDownloads()`, and
add `showDownloads` to `EpisodesView.init` as a defaulted parameter alongside
`currentCacheState`.

- [ ] **Step 5: Build and hand-verify**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

Then in the Simulator, confirm each of these still works — this task has no test coverage, and a desynced stack shows up as a screen that will not pop:
1. TV tab → tap a show → episodes appear → Back returns to the grid.
2. Movies tab → tap a poster → detail appears → Back returns to the grid.
3. Options menu → Download all → confirm → Downloads is pushed → Back works.
4. Inside a show → Download all → Downloads is pushed → Back returns to the episode list, not the grid.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Sources/ShowsView.swift \
        ios/PatataTube/Sources/MovieCell.swift \
        ios/PatataTube/Sources/EpisodesView.swift
git commit -m "refactor(ios): drive grid navigation from an explicit route path"
```

---

### Task 6: Record state as it changes

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift` (property list at the top)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift` (the `scenePhase` `onChange`)

**Interfaces:**
- Consumes: `RestorationStore`, `RestorationState`, `PlayerState` (Task 1); `path` (Task 5).
- Produces: `AppModel.restoration: RestorationStore`.

- [ ] **Step 1: Expose the store on AppModel**

In `AppModel.swift`, next to `videoListCache`:

```swift
    /// Where the app was when it last went away: tab, pushed screens, scroll
    /// anchors, search, in-flight playback.
    let restoration = RestorationStore()
```

- [ ] **Step 2: Record on every change**

In `VideoGridView.swift`, add these modifiers next to the existing
`.onChange(of: model.webBridgeRequests)`:

```swift
            .onChange(of: path) { _, newValue in
                model.restoration.mutate { $0.path = newValue }
            }
            .onChange(of: store.filter) { _, newValue in
                model.restoration.mutate { $0.filter = newValue }
            }
            .onChange(of: activeSearch) { _, newValue in
                model.restoration.mutate { $0.search = newValue }
            }
            .onChange(of: playing) { _, newValue in
                model.restoration.mutate {
                    $0.player = newValue.map {
                        PlayerState(videoID: $0.videos[$0.startIndex].id,
                                    versionID: $0.videos[$0.startIndex].chosenVersionId,
                                    sleepMode: $0.sleepMode)
                    }
                }
            }
```

`PlaybackQueue` is already `Equatable`, so `onChange(of: playing)` compiles as
is. Recording the item at `startIndex` rather than `id` keeps it correct if the
queue is ever presented at a non-zero index.

- [ ] **Step 3: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify what gets written**

Run the app in the Simulator, navigate into a show, then background it
(Device ▸ Home). Confirm the blob exists and looks right:

```bash
xcrun simctl spawn booted defaults read com.grillermo.PatataTube restorationState
```

Expected: a JSON blob (printed as base64 or bytes) containing the show title.
If `defaults read` prints raw bytes, decode with:

```bash
xcrun simctl spawn booted defaults export com.grillermo.PatataTube - \
  | plutil -extract restorationState raw -o - - | base64 -d
```

(Use the bundle id from `ios/PatataTube/project.yml` if it differs.)

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/AppModel.swift \
        ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): record navigation, search and playback state"
```

---

### Task 7: Restore at boot

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift` (`initialLoad()` at ~line 329)

**Interfaces:**
- Consumes: `RestorationResolver.resolve` (Task 3), `PlaybackQueue.startPaused` (Task 4), `path` (Task 5), `AppModel.restoration` (Task 6).
- Produces: nothing downstream.

- [ ] **Step 1: Apply the resolved state**

Replace `initialLoad()` with:

```swift
    private func initialLoad() async {
        let api = APIClient(store: model.credentials)
        if let list = try? await api.classifications() { classifications = list }

        let saved = model.restoration.load()
        await store.bootLoad()

        // Order is load-bearing: videos must be loaded before any id resolves,
        // and the search has to be applied first because it decides which rows
        // the show/movie routes are resolved against.
        searchText = saved.search
        activeSearch = saved.search
        let resolved = RestorationResolver.resolve(
            state: saved,
            videos: filteredVideos,
            hasPendingQuickAction: QuickActionRouter.shared.pending != nil
        )
        path = resolved.path
        if let player = resolved.player {
            DevLog.event(.lifecycle, "restoring player", [
                "video_id": "\(player.video.id)", "queue": "\(player.queue.count)",
            ])
            playing = PlaybackQueue(
                video: player.video,
                queueSnapshot: player.queue,
                sleepMode: player.sleepMode,
                startSecs: model.resumeStore.local(for: player.video.id) ?? player.video.resumeSecs,
                startPaused: true
            )
        }

        // Footprint after the list lands: correlates library size + in-flight
        // downloads with the OOM watchdog kills (PATATATUBE-6, -2).
        MemoryProbe.snapshot("grid-loaded", extra: [
            "video_count": store.videos.count,
            "active_downloads": model.cache.activeDownloads().count,
        ])
    }
```

The position falls back to the server-provided `video.resumeSecs` when the
local mirror has nothing, matching how `ResumeDecision` is fed elsewhere.

- [ ] **Step 2: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Hand-verify restoration**

In the Simulator:
1. TV tab → open a show → kill the app (stop in Xcode) → relaunch. Expect: the episode list, not the grid.
2. Play an episode ~30s in → kill → relaunch. Expect: the player, paused, seeked to ~30s, over that show's episodes.
3. Search "bear" → kill → relaunch. Expect: the search text and filtered grid come back.
4. Delete the restored video from the server (or point at a different server) → relaunch. Expect: the grid, no crash, no empty screen.

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift
git commit -m "feat(ios): restore screen, search and playback at launch"
```

---

### Task 8: Scroll anchors

**Files:**
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/PatataTube/Sources/ShowsView.swift`
- Modify: `ios/PatataTube/Sources/EpisodesView.swift`

**Interfaces:**
- Consumes: `VisibleItemsTracker` (Task 2), `RestorationState.gridKey`/`showKey` (Task 1), `AppModel.restoration` (Task 6).
- Produces: nothing downstream.

Anchor ids are strings so one tracker type serves both screens: video cells use
`String(video.id)`, show cells use `show.id` (the title).

- [ ] **Step 1: Add a reusable anchor modifier**

Create the helper at the bottom of `VideoGridView.swift` (same file — it is
used by all three views and is small):

```swift
/// Records the topmost visible cell for one screen and restores it on first
/// appearance. Anchors are per screen key, so each tab and each show remembers
/// its own position.
///
/// `ScrollViewReader` rather than `.scrollPosition(id:)` because the latter
/// does not cover `List` on iOS 17, which `EpisodesView` uses.
@MainActor
struct ScrollAnchor {
    let key: String
    let store: RestorationStore
    let tracker: VisibleItemsTracker

    /// Callers debounce this (0.5s) so a flick does not write to UserDefaults
    /// on every frame.
    func record() {
        guard let top = tracker.topmost else { return }
        store.mutate { $0.scrollAnchors[key] = top }
    }

    var saved: String? { store.load().scrollAnchors[key] }
}

extension View {
    /// Attach to each cell: reports visibility to the tracker.
    func anchorItem(_ id: String, tracker: VisibleItemsTracker) -> some View {
        onAppear { tracker.appeared(id) }
            .onDisappear { tracker.disappeared(id) }
    }
}
```

- [ ] **Step 2: Wire the root grid**

In `VideoGridView.swift`, add state:

```swift
    @State private var gridTracker = VisibleItemsTracker()
    @State private var anchorDebounceTask: Task<Void, Never>?
    @State private var restoredAnchorKey: String?
```

Wrap the existing `ScrollView` in a `ScrollViewReader` and keep the tracker fed:

```swift
            ScrollViewReader { proxy in
                ScrollView {
                    // ...existing content unchanged...
                }
                .onChange(of: filteredVideos) { _, videos in
                    gridTracker.setOrder(store.filter == "tv"
                        ? ShowGroup.group(videos).map(\.id)
                        : videos.map { String($0.id) })
                    restoreGridAnchor(proxy)
                }
                .onAppear { restoreGridAnchor(proxy) }
            }
```

Add the two helpers next to `initialLoad()`:

```swift
    private var gridAnchor: ScrollAnchor {
        ScrollAnchor(key: RestorationState.gridKey(filter: store.filter),
                     store: model.restoration, tracker: gridTracker)
    }

    /// Runs once per screen key: re-scrolling on every list refresh would yank
    /// the user back while they read.
    private func restoreGridAnchor(_ proxy: ScrollViewProxy) {
        let key = RestorationState.gridKey(filter: store.filter)
        guard restoredAnchorKey != key, !filteredVideos.isEmpty else { return }
        restoredAnchorKey = key
        guard let saved = gridAnchor.saved else { return }
        proxy.scrollTo(saved, anchor: .top)
    }

    private func recordGridAnchor() {
        anchorDebounceTask?.cancel()
        anchorDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            gridAnchor.record()
        }
    }
```

Tag the cells. In the non-TV `LazyVGrid` branches add to each cell:

```swift
                            .id(String(video.id))
                            .anchorItem(String(video.id), tracker: gridTracker)
                            .onAppear { recordGridAnchor() }
```

for both `VideoCell` and `MovieCell`.

- [ ] **Step 3: Wire the shows grid**

`ShowsView` needs the same treatment for the TV tab. Give it two parameters:

```swift
    let tracker: VisibleItemsTracker
    let onScroll: () -> Void
```

and tag each show cell inside the `ForEach`:

```swift
                .id(show.id)
                .anchorItem(show.id, tracker: tracker)
                .onAppear { onScroll() }
```

Pass `tracker: gridTracker, onScroll: { recordGridAnchor() }` from
`VideoGridView`.

- [ ] **Step 4: Wire the episode list**

In `EpisodesView.swift`, add:

```swift
    @EnvironmentObject var model: AppModel   // already present
    @State private var tracker = VisibleItemsTracker()
    @State private var anchorDebounceTask: Task<Void, Never>?
    @State private var restored = false
```

Wrap the `List` in a `ScrollViewReader`, tag rows, and restore once:

```swift
        ScrollViewReader { proxy in
            List {
                ForEach(show.seasons(), id: \.number) { season in
                    Section("Season \(season.number)") {
                        ForEach(season.episodes) { episode in
                            row(for: episode)
                                .id(String(episode.id))
                                .anchorItem(String(episode.id), tracker: tracker)
                                .onAppear { recordAnchor() }
                        }
                    }
                }
            }
            .onAppear {
                tracker.setOrder(show.episodes.map { String($0.id) })
                guard !restored else { return }
                restored = true
                if let saved = anchor.saved { proxy.scrollTo(saved, anchor: .top) }
            }
        }
```

with the same helpers, keyed by show:

```swift
    private var anchor: ScrollAnchor {
        ScrollAnchor(key: RestorationState.showKey(title: show.title),
                     store: model.restoration, tracker: tracker)
    }

    private func recordAnchor() {
        anchorDebounceTask?.cancel()
        anchorDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            anchor.record()
        }
    }
```

- [ ] **Step 5: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Hand-verify**

1. Children tab → scroll halfway → kill → relaunch. Expect: roughly the same rows on screen.
2. Switch to Movies, scroll, switch back to Children. Expect: Children is still where it was.
3. Open a show → scroll to season 3 → kill → relaunch. Expect: the episode list at season 3.
4. Change the grid cell size with +/- after restoring. Expect: no jump, no crash.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Sources/ShowsView.swift \
        ios/PatataTube/Sources/EpisodesView.swift
git commit -m "feat(ios): restore scroll position per screen"
```

---

### Task 9: Flush on background, and document the manual checks

**Files:**
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift` (the `scenePhase` `onChange`)
- Modify: `ios/README.md`
- Modify: `CLAUDE.md` (the iOS section)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Flush the anchor on background**

The anchor write is debounced 0.5s; backgrounding inside that window would drop
it. In `PatataTubeApp.swift`, in the existing `else` branch next to
`DevLog.flush()`:

```swift
                    } else {
                        // Last chance to get pending records out before the app
                        // is suspended or killed.
                        DevLog.flush()
                        model.flushRestoration()
                    }
```

In `AppModel.swift`, add the hook the grid registers into:

```swift
    /// Set by the grid so a debounced scroll anchor still lands when the app is
    /// backgrounded mid-debounce.
    var restorationFlush: (@MainActor () -> Void)?

    func flushRestoration() { restorationFlush?() }
```

In `VideoGridView.swift`, register it in `initialLoad()` (last line, after the
`MemoryProbe.snapshot`):

```swift
        model.restorationFlush = { gridAnchor.record() }
```

- [ ] **Step 2: Build**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Add the manual checklist**

Append to the manual test checklist in `ios/README.md`:

```markdown
### State restoration

Each of these is "do the thing, kill the app from Xcode, relaunch":

- [ ] Each classification tab restores its own scroll position.
- [ ] Inside a show, the episode list and its scroll position come back.
- [ ] A movie detail screen comes back.
- [ ] The Downloads screen comes back, and Back returns to whatever pushed it.
- [ ] Search text comes back, with the grid filtered.
- [ ] Playing mid-episode: the player reopens **paused**, seeked to the resume
      point, queued over that show's episodes. Pressing play continues; the
      next episode auto-advances and plays normally (not paused).
- [ ] Delete the restored video server-side first: the app opens on the grid,
      no crash, no blank screen.
- [ ] Restoration survives a swipe-kill from the app switcher (this is why the
      state lives in UserDefaults, not @SceneStorage).
- [ ] A Home-screen quick action opens its own destination, not the restored
      player.
```

- [ ] **Step 4: Document the behaviour**

Add to the iOS section of `CLAUDE.md`, after the resume-positions bullet:

```markdown
- **The app reopens where it was left.** `RestorationStore` (UserDefaults key
  `restorationState`) persists the classification tab, an id-only navigation
  path (`Route`), per-screen scroll anchors, the committed search text and any
  in-progress playback. `VideoGridView` therefore drives an explicit
  `NavigationStack(path:)` — **`.downloads` is a route, not an `isPresented`
  destination**, because SwiftUI desyncs a stack that mixes the two. At boot
  `RestorationResolver.resolve` validates the blob against the loaded list and
  drops routes that no longer resolve (along with everything pushed after
  them); the restored player mounts **paused** at its `ResumePositionStore`
  position. There is no expiry. A pending quick action outranks player
  restoration.
```

- [ ] **Step 5: Run the full package test suite**

Run: `cd ios/PatataTubeKit && swift test`
Expected: the three new suites pass. Known pre-existing noise in a full parallel
run (swift-testing `Index out of range`, `VideoStoreTests` flakes) is not a
regression — re-run any failure filtered to confirm before acting on it.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources/PatataTubeApp.swift \
        ios/PatataTube/Sources/AppModel.swift \
        ios/PatataTube/Sources/VideoGridView.swift \
        ios/README.md CLAUDE.md
git commit -m "feat(ios): flush restoration on background and document it"
```

---

## Out of scope

Per the spec: Settings, Upload and Web bridge presentation state; multi-window
state; any change to how resume positions are recorded or reported.
