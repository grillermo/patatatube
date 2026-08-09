# Pausable downloads — design

Date: 2026-08-08
Status: approved, not yet implemented

## Goal

Each in-progress download row in the iOS Downloads view gets a trailing three-dot
menu. Cancel moves off the row and into that menu. The menu also offers Pause;
a paused download offers Resume instead. Pausing survives quitting the app.

## Decisions taken during brainstorming

- **Menu scope: Downloads view only.** The cancel context menus on
  `VideoCell` / `VideoRow` / `MovieDetailView` stay exactly as they are.
- **HLS packages can be paused too**, even though nothing partial is kept on
  disk for them; resuming one restarts from zero. Uniform UI beats a menu that
  silently varies per row.
- **Pausing does not free a concurrency slot.** The gate permit stays held for
  as long as the download is paused, including across app restarts, where each
  paused entry re-reserves a permit at launch. No deadlock guard: if the user
  paused enough downloads to fill the limit, nothing else runs until they act.
- **Nothing auto-resumes.** Not on launch, not on foreground, not on network
  change. Only the Resume menu item.
- **Paused rows stay in the "In Progress" section**, labeled Paused, so a row
  never jumps between sections when toggled.

## Components

### `PausedDownloadStore` (PatataTubeKit, new file)

Persists paused downloads as `paused-downloads.json` in the cache root,
following `DownloadCompletionHistoryStore`: load in `init`, rewrite the whole
file on every mutation, best-effort (`try?`) throughout.

```swift
public struct PausedDownload: Codable, Equatable, Identifiable, Sendable {
    public let videoID: Int
    public let versionID: Int?
    public let remoteURL: URL
    /// True when `remoteURL` is an HLS master playlist, so resuming goes
    /// through `downloadHLS` rather than `download` — two different entry
    /// points, and nothing on disk distinguishes them for an HLS row.
    public let isHLS: Bool
    public let streamCount: Int
    public let previewURL: URL?
    public let showPosterKey: String?
    public let showPosterURL: URL?
    public let progress: Double
    public let transferredByteCount: Int64
    public let totalByteCount: Int64?
    public var id: String { versionID.map { "\(videoID):\($0)" } ?? "\(videoID)" }
}
```

`id` is the existing cache key format, so the store is keyed the same way as
`inFlight`, `tasksByKey`, and `segmentedAttempts`.

The remote URL and the download parameters are persisted because the
external/HLS path has no on-disk state to rebuild them from. The segmented and
plain paths could recover them from their manifest or resume data, but one
uniform entry is cheaper than three recovery routes.

No capacity cap: entries only appear by explicit user action and only leave by
explicit user action.

### `CacheManager.pause(id:versionId:)`

Deliberately **not** `cancel(id:)` — that method exists to wipe resume state so
a re-tap starts clean. Pause preserves it. Per path:

| path | pause | resume |
|---|---|---|
| segmented | stop the segment data tasks; **keep** the manifest and partial part files (the durable state) | re-request remaining bytes via `Range: bytes=(start+partSize)-(end)` + `If-Range` from part file size; `startIncompleteSegments` reuses existing logic |
| plain `URLSession` | `task.cancel(byProducingResumeData:)`, write `{key}.resume` | `session.downloadTask(withResumeData:)` |
| external / HLS | `cancelExternalActivity(key:)`, drop the partial package directory | fresh download from zero |

Order of operations, so no other code path can undo the pause mid-flight:

1. Insert the key into the paused set (in-memory, under `lock`).
2. Snapshot the current activity into a `PausedDownload` and persist it.
3. Remove the key from `inFlight` (freezes the speed meter's view of it).
4. Tear the transfer down per the table above.

The awaiting `download(id:)` call unwinds with `CancellationError` as it does
today; step 1 is what makes its `defer` keep the permit (see below).

**Durability model (segmented path only):** Part files are the durable record
of a segment's progress. Segments append data directly to part files via data
tasks (not download tasks); on pause, the part file's current size is the byte
count to resume from. The plain `URLSession` path is unchanged — it still uses
Apple's resume-data mechanism for both pause and resume, unchanged from before
this durability model was added.

### `CacheManager.resume(id:versionId:)`

Removes the entry from the store and the paused set, re-inserts an
accumulator into `inFlight` seeded with the persisted byte counts, then starts
the transfer through a path that **does not acquire** the gate — the permit is
already held. Releases that permit when the transfer finishes or fails.

Cancelling a paused row (same menu) removes the store entry, releases the
reserved permit, and deletes the partial state exactly as `cancel(id:)` does.

### Permit ownership

`download(id:versionId:…)` currently does `defer { concurrencyGate.release() }`.
That becomes `defer { releasePermit(for: key) }`, which under `lock` checks the
paused set: if the key is paused, the permit is recorded as owned by the paused
reservation table and **not** returned to the gate; otherwise it releases as
before.

At launch, `CacheManager` spawns one detached task per stored paused entry that
awaits `concurrencyGate.acquire()` and parks, holding the permit until that
entry is resumed or cancelled. These reservations queue through the gate like
any other acquirer, so a launch with more paused entries than the limit simply
grants them in order.

Resume reuses the already-held permit rather than re-acquiring, so it starts
immediately instead of queueing behind whatever is pending.

### `resumeInterrupted()` must skip paused keys

It walks segmented manifests and `*.resume` files — precisely the artifacts a
paused download deliberately leaves behind. Without a guard, the first
foreground after a pause would silently restart it. Both loops gain a
`pausedStore.contains(key)` check alongside the existing
`tasksByKey[key] != nil` / `inFlight[key] != nil` guards.

### Visibility

`DownloadActivity` gains `isPaused: Bool` defaulting to `false`, so every
existing construction site and test compiles unchanged.

`CacheManager.activeDownloads()` returns live activities merged with paused
entries mapped to `DownloadActivity(isPaused: true)`, sorted by `id` as today.
Paused entries stay **out of** `inFlight`, so `downloadedByteCount()` and the
speed meter are untouched by them.

`state(for:)` returns `.downloading(progress)` for a paused key, using the
persisted progress. No new `CacheState` case: a frozen ring in the grid is the
right affordance, and every `switch` over `CacheState` in the app stays as is.

### `DownloadsView` row

`activeRow` drops the inline `Button("Cancel")` and gains a trailing:

```swift
Menu {
    if item.isPaused {
        Button("Resume", systemImage: "play.fill") { onResume(item) }
    } else {
        Button("Pause", systemImage: "pause.fill") { onPause(item) }
    }
    Button("Cancel download", systemImage: "xmark.circle", role: .destructive) {
        onCancel(item)
    }
} label: {
    Image(systemName: "ellipsis.circle")
}
```

A paused row shows a "Paused" caption under the title and its progress bar
frozen at the persisted value. Two new closure properties, `onPause` and
`onResume`, are wired in `VideoGridView` (the single construction site, around
`VideoGridView.swift:692`) to `model.cache.pause` / `model.cache.resume`.

Both new closures get defaults (`{ _ in }`) so existing `DownloadsView`
constructions in tests and previews keep compiling.

## Error handling

- Every store write is best-effort. A failed persist means the pause does not
  survive a quit; the in-memory pause still holds. Not worth surfacing.
- Resuming an entry whose partial state has vanished (manifest gone, `.resume`
  corrupt, package deleted by `clearAllVideos`) falls through to a fresh
  download from zero — the existing paths already handle missing resume data
  this way.
- `clearAllVideos()` clears the paused store and releases all reserved permits,
  otherwise permits would leak for entries whose files it just deleted.
- A pause racing a completing download: step 1 takes `lock`, and the completion
  path removes the key from `inFlight` under the same lock. Whichever lands
  first wins. If completion wins, a stale paused entry can be left behind, so
  the paused-entry merge in `activeDownloads()` skips (and drops from the
  store) any entry whose local file now exists — the same staleness check
  `recentDownloads()` already applies to completion history.

## Testing

PatataTubeKit (`swift test`):

- `PausedDownloadStore` round-trips through a temp root; a corrupt file loads as
  empty.
- Pausing a segmented download keeps its manifest and partial files.
- Pausing a plain download writes `{key}.resume`.
- `resumeInterrupted()` does not restart a paused key.
- The gate permit is still held after a pause (spy gate: `release` not called),
  and resume does not acquire a second one.
- Cancelling a paused entry releases the permit and empties the store.
- `activeDownloads()` includes paused entries with `isPaused == true`;
  `downloadedByteCount()` is unaffected by them.

App target (`xcodebuild … test`, `DownloadsViewTests`):

- A live row's menu offers Pause; a paused row's offers Resume.
- `onPause` / `onResume` / `onCancel` fire from the menu items.
- A paused row renders the "Paused" caption.

Per `CLAUDE.md`, neither suite is run without an explicit request.
