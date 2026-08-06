# iOS state restoration — resume where you left off

Date: 2026-08-02
Status: design approved, not implemented

## Problem

Closing and reopening the app always lands on the root grid, scrolled to top.
The only thing that survives a relaunch is the selected classification tab
(`VideoStore.filter`, persisted under `selectedClassification`). The pushed
screen (a show's episode list, a movie detail), the scroll position, the search
query, and any in-progress playback are all lost.

Goal: reopening the app returns to the exact screen, scroll position, and video
the user left.

## Decisions

| Question | Decision |
|---|---|
| Depth | Tab + pushed screens + scroll position + reopen the player |
| Expiry | Never. A relaunch a week later still restores. |
| Player behaviour | Opens seeked to the resume point, **paused**. No alert, no surprise audio. |
| Scroll fidelity | Scroll to the last visible item, not a pixel offset. Survives list and cell-size changes. |
| Also restored | Active search text; Downloads screen (as an ordinary route) |
| Not restored | Settings, Upload, Web bridge sheets — always start closed |

Storage is `UserDefaults`, not `@SceneStorage`. `@SceneStorage` was considered
and rejected: SwiftUI deletes it when the scene is discarded (swipe out of the
app switcher), and the system drops restoration state after abnormal
terminations — this app takes OOM/watchdog kills (Sentry PATATATUBE-2, -6),
which are exactly the launches where restoring matters most. It would also
still need a `Codable` route enum, so it saves no types.

## Data model (PatataTubeKit)

```swift
public enum Route: Codable, Hashable, Sendable {
    case show(title: String)   // ShowGroup.id
    case movie(id: Int)        // Video.id
    case downloads
}

public struct PlayerState: Codable, Equatable, Sendable {
    public var videoID: Int
    public var versionID: Int?
    public var sleepMode: Bool
}

public struct RestorationState: Codable, Equatable, Sendable {
    public var filter: String?
    public var path: [Route]                    // root-first
    public var search: String                   // activeSearch
    public var scrollAnchors: [String: String]  // screenKey -> item id
    public var player: PlayerState?
}
```

Routes store **ids, not values**. A `Route` never carries a `Video` or
`ShowGroup`; those are resolved against the loaded list at render time. That is
what makes a stale path safe — a deleted video or renamed show resolves to
nothing and the route is dropped, rather than being decoded into a phantom row.
It also keeps the persisted blob small.

`filter` is recorded for consistency but is **not** applied at boot:
`VideoStore` already persists and restores the selected classification itself
(`selectedClassification`). The field exists so the blob is self-describing and
so `scrollAnchors` keys can be validated against the tab they belong to; nothing
writes `store.filter` from it.

`scrollAnchors` is keyed per screen: `"grid:<filter>"` for the root grid,
`"show:<title>"` for an episode list. Switching tabs and re-entering a show both
land where they were left.

`RestorationStore` is a thin `UserDefaults` wrapper (key `restorationState`,
JSON-encoded) in the shape of the existing `ResumePositionStore` and
`WebHistoryStore`: `load() -> RestorationState?` and `save(_:)`. No expiry
field, no TTL check.

## Navigation restructure

`VideoGridView` currently uses an implicit `NavigationStack` with three
independent destination declarations. Restoration requires an explicit path
binding: `@State private var path: [Route] = []` and
`NavigationStack(path: $path)`.

Three call sites convert:

1. `ShowsView` — `NavigationLink(value: show)` becomes
   `NavigationLink(value: Route.show(title: show.title))`, and its
   `.navigationDestination(for: ShowGroup.self)` moves up into `VideoGridView`.
   `ShowsView` no longer owns a destination.
2. `MovieCell` — `NavigationLink(value: video)` becomes
   `Route.movie(id: video.id)`; `.navigationDestination(for: Video.self)` folds
   into the same switch.
3. `.navigationDestination(isPresented: $showDownloads)` becomes
   `path.append(.downloads)`. **Required, not cosmetic**: mixing an
   `isPresented` destination with a `path` binding is unsupported by SwiftUI and
   desyncs the stack. The Download-all confirm site (`showDownloads = true`) and
   `EpisodesDownloadAllState.showDownloads` both become path appends.

One destination switch on `VideoGridView` resolves ids at render time:

- `.show(title)` → `ShowGroup.group(filteredVideos).first { $0.id == title }` →
  `EpisodesView`
- `.movie(id)` → `store.videos.first { $0.id == id }` → `MovieDetailView`
- `.downloads` → `DownloadsView`, wired exactly as today

An unresolvable route pops rather than rendering an empty screen.

## Scroll anchors

A `VisibleItemsTracker` in PatataTubeKit holds the set of on-screen item ids,
fed by `.onAppear` / `.onDisappear` on each cell, and reports the id earliest in
the current ordering — the topmost visible item. Pure logic, no SwiftUI types,
unit-testable.

Restore is `ScrollViewReader` plus a single `scrollTo(anchor, anchor: .top)` on
first appearance of the screen. `ScrollViewReader` rather than
`.scrollPosition(id:)` because the latter does not cover `EpisodesView`'s `List`
on iOS 17, which is the deployment target (`project.yml`, `Package.swift`).

Anchor writes debounce 0.5s, matching the existing search debounce, so scrolling
does not write to `UserDefaults` on every frame.

## Player restoration

`PlayerState` persists only `videoID`, `versionID`, and `sleepMode`. The queue
is **rebuilt** on launch, not persisted:

- top route is `.show(title)` → that show's episodes
- otherwise → `filteredVideos`

`startIndex` is the position of `videoID` in that queue. `startSecs` comes from
the existing `ResumePositionStore` — server-backed resume positions are already
mirrored there, so restoration adds no new position storage.

`VideoPlayerView` gains `startPaused: Bool = false`. It seeks exactly as it does
today and skips the `play()` call. `PlaybackQueue` carries the flag through.

`playing` is cleared — and the persisted `player` with it — when the cover
dismisses.

## Boot sequence

In `VideoGridView.initialLoad()`. Order is load-bearing:

1. `RestorationStore.load()`
2. `await store.bootLoad()` — videos must be present before any id resolves
3. apply `search` to `searchText` / `activeSearch` — it changes
   `filteredVideos`, which show and movie resolution read
4. set `path`, pruned: a route that does not resolve is dropped **along with
   everything after it** (a movie pushed from inside a deleted show is
   unreachable)
5. present the player if its `videoID` still resolves in the rebuilt queue
6. each screen applies its own scroll anchor as it appears

A pending quick action (`QuickActionRouter.pending`) takes precedence over
player restoration: an explicit launch intent must not be overridden by the
previous session.

Steps 1–5 are expressed as one pure function so they can be tested without a
running app:

```swift
public struct ResolvedPlayer: Equatable, Sendable {
    public var video: Video
    public var index: Int
    public var sleepMode: Bool
}

public struct ResolvedRestoration: Equatable, Sendable {
    public var path: [Route]
    public var search: String
    public var player: ResolvedPlayer?
}

enum RestorationResolver {
    static func resolve(state: RestorationState,
                        videos: [Video],
                        hasPendingQuickAction: Bool) -> ResolvedRestoration
}
```

## Save triggers

Write on change of `path`, `store.filter`, `activeSearch`, `playing`, and on
debounced anchor updates. Plus a flush in the `scenePhase != .active` branch
already present in `PatataTubeApp`, next to the existing `DevLog.flush()`.

Writes are a small JSON blob to `UserDefaults` on the main actor. This is
deliberate and safe at this size; the debounce keeps the frequency low. Do not
move it to a background queue without a reason — ordering against `scenePhase`
matters more than the microseconds.

## Testing

Package tests (`swift test`), all against the pure pieces:

- `RestorationState` JSON round-trip, including `Route` cases
- path pruning: show deleted → route and its suffix dropped
- path pruning: movie id gone → route dropped
- player dropped when its video no longer resolves
- player queue rebuilt from a show's episodes when the top route is `.show`
- quick action pending → player restoration suppressed
- `VisibleItemsTracker` reports the topmost id under appear/disappear sequences,
  including out-of-order callbacks

View wiring has no automated coverage — there is no iOS test target. Add a
manual checklist to `ios/README.md`: background and relaunch from each tab, from
inside a show, from a movie detail, from the Downloads screen, mid-playback, and
after deleting the restored video from the server.

## Out of scope

- Settings, Upload, and Web bridge presentation state. The web bridge already
  reopens on its last page via `WebHistoryStore.lastURL` once opened.
- Multi-window / multi-scene state. Restoration is a single blob; a second
  window would restore the same state.
- Any change to how resume positions are recorded or reported.
