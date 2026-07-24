# iOS Clear Cache Quick Actions — Design

Date: 2026-07-23

## Goal

Add four iOS home-screen quick actions (long-press app icon) that each clear one
category of cached/persisted state. No confirmation dialogs — each tap acts
immediately.

## The four actions

Delivered as static `UIApplicationShortcutItems` in `Info.plist` (exactly four,
matching the iOS home-screen cap).

| Title | Type identifier | Icon | Wipes | Keeps |
|---|---|---|---|---|
| Clear Videos | `com.patatatube.clearVideos` | `film` | every `*.mp4` (all versions) + `*.resume` + segment manifests + completion history; cancels in-flight downloads | covers, lists, login |
| Clear Covers | `com.patatatube.clearCovers` | `photo` | every `*.preview.*` + `poster.*` image | videos, lists, login |
| Clear Lists | `com.patatatube.clearLists` | `list.bullet` | `Caches/video-lists/*.json` + in-memory `VideoStore.videos` | files, login |
| Reset Settings | `com.patatatube.resetSettings` | `gearshape` | Keychain token + `patatatube.baseURL` (**logs out**) + download settings back to defaults | nothing cache-side |

`Reset Settings` is the only destructive-to-login action. Chosen deliberately with
no confirmation.

## Cache layout (source of truth)

`CacheManager.root` = `Documents/videos/` holds, keyed by filename prefix:

- Videos: `{id}.mp4`, `{id}.v{ver}.mp4`
- Resume data: `{id}.resume`, `{id}:*.resume`
- Segment manifests: owned by `segmentedStore` (`SegmentedDownloadStore`)
- Completion history: owned by `completionHistory` (`DownloadCompletionHistoryStore`)
- Previews: `{id}.preview.*`
- Show posters: `poster.{hash}.*`

`VideoListCache.root` = `Caches/video-lists/` holds `{classification|all}.json`.

Login/server lives outside `videos/`: Keychain (`patatatube.uploadToken`) +
`UserDefaults` key `patatatube.baseURL`. Download settings live in `UserDefaults`
keys `downloadStreamCount` and `simultaneousDownloadCount`.

## Kit changes (PatataTubeKit — public, unit-testable via `swift build`)

### `CacheManager.clearAllVideos()`
Dir-wide generalization of the existing `removeAllCached(id:)`:
1. Cancel every in-flight download (iterate current `inFlight`/`tasksByKey`, cancel tasks).
2. Remove every file in `root` matching `*.mp4` or `*.resume`.
3. Remove all segment manifests (`segmentedStore.manifests()` → `remove(cacheKey:)`).
4. Clear completion history (`completionHistory` — add a `clear()` if absent).
5. Reset in-memory `inFlight` and recent-downloads state so the UI reflects empty.

Covers and posters are explicitly left untouched (mirrors `removeAllCached`'s
existing "keep previews/posters" contract, generalized).

### `CacheManager.clearAllCovers()`
Remove every file in `root` matching `*.preview.*` or `poster.*`. Leaves videos,
resume data, manifests, history.

### `VideoListCaching.clear()`
New protocol method. `VideoListCache.clear()` removes the `video-lists/` directory
(best-effort) and recreates it empty. `InMemory`/test doubles implement trivially.

### `VideoStore.clearListCache()`
Calls `cache.clear()` (the list cache), then empties the published `videos` array
on the main actor.

## App changes (PatataTube shell)

### `AppModel`
Four `@MainActor` methods:

- `clearVideos()` → `cache.clearAllVideos()`, then `await store.load()` (refresh from server if reachable).
- `clearCovers()` → `cache.clearAllCovers()`, then `await store.load()`.
- `clearLists()` → `store.clearListCache()`, then `await store.load()`.
- `resetSettings()` →
  - `credentials.token = nil`; `credentials.baseURL = nil`
  - remove `downloadStreamCount` + `simultaneousDownloadCount` from `UserDefaults` (or write defaults via the settings structs)
  - reset `@Published` mirrors: `tokenText = ""`, `baseURLText = ""`, `downloadStreamCount`/`downloadConcurrency` to defaults
  - `cache.setMaxConcurrentDownloads(default)`
  - No `store.load()` (no credentials → nothing to load); leave list as-is or empty per existing offline behavior.

### Quick-action routing
SwiftUI is scene-based (`@UIApplicationDelegateAdaptor`, no scene delegate today).
Cold-launch shortcuts arrive via the scene's connection options, so a scene
delegate is required.

- `QuickActionRouter`: `@MainActor final class ... : ObservableObject` singleton
  (`.shared`) with `@Published var pending: QuickAction?` where
  `enum QuickAction { case clearVideos, clearCovers, clearLists, resetSettings }`,
  mapped from the shortcut `type` string.
- `AppDelegate.application(_:configurationForConnecting:options:)` returns a
  `UISceneConfiguration` naming a `SceneDelegate: UIResponder, UIWindowSceneDelegate`.
- `SceneDelegate.scene(_:willConnectTo:options:)` reads
  `connectionOptions.shortcutItem` (cold launch) → sets `router.pending`.
- `SceneDelegate.windowScene(_:performActionFor:completionHandler:)` (warm/back-
  grounded) → sets `router.pending`, calls `completionHandler(true)`.
- `RootView` observes `QuickActionRouter.shared` (via `.onChange(of:)` /
  `.onReceive`) and dispatches to the matching `AppModel` method, then clears
  `pending`.

## Error handling

All deletes are best-effort `try?` (matches existing `CacheManager` idiom). A
partially-populated directory or a missing file never throws to the user. In-flight
cancellation is fire-and-forget; the OS may still write a final chunk before the
cancel lands — acceptable, next launch's `resumeInterrupted` finds no manifest and
does nothing.

## Testing

- PatataTubeKit unit tests (build a `CacheManager` with a temp `root`, seed fake
  files, assert `clearAllVideos()` / `clearAllCovers()` remove exactly the right
  prefixes and leave the others): the testable core.
- `VideoListCache.clear()` test with a temp `root`.
- Quick-action wiring + `AppModel.resetSettings()` are app-shell (no iOS test
  target) → manual verification per `ios/README.md`: long-press icon, run each of
  the four actions, confirm scoped wipe and that unrelated caches/login survive
  (except Reset Settings logging out).

## Out of scope

- No in-app Settings buttons (home-screen quick actions only).
- No confirmation dialogs.
- No dynamic shortcut badges/counts.
