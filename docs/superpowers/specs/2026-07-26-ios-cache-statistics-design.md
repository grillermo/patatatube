# iOS cache statistics section

**Date:** 2026-07-26
**Status:** approved design

## Goal

Show, inside the iOS Settings screen, how much disk each of the app's caches
uses. Read-only: sizes and item counts, no clearing, no device-disk context.
Every cache gets its own row rather than being grouped, so a large number can be
traced to a specific store.

## What caches exist today

| Cache | Location | Owner |
|---|---|---|
| Proxy HLS segments | `Caches/stream/hls/` | `StreamCache` / `SegmentCache` |
| Proxy MP4 ranges | `Caches/stream/mp4/` | `StreamCache` / `RangeStore` |
| Offline videos | `Documents/videos/{id}.mp4`, `{id}.v{ver}.mp4` | `CacheManager` |
| Offline HLS packages | `Documents/videos/hls-{id}`, `hls-{id}_v{ver}` | `CacheManager+HLS` |
| Covers | `Documents/videos/{id}.preview.{hash}.{ext}`, `poster.{hash}.{ext}` | `CacheManager` |
| Partial downloads | `Documents/videos/.downloads/{cacheKey}/`, `*.resume` | `SegmentedDownloadStore` |
| Download history | `Documents/videos/download-completions.json` | `DownloadCompletionHistoryStore` |
| Video list cache | `Caches/video-lists/*.json` | `VideoListCache` |
| Staging temp | `tmp/patatatube-seed-*` | `CacheManager` seeding |
| Image bytes (RAM) | `NSCache`, 64 MB cap | `ImageMemoryCache` |

The RAM cache is **out of scope**: `NSCache` exposes no current-usage figure, and
tracking it accurately would require an eviction delegate for a transient,
self-managing store.

## Data model

New file `ios/PatataTubeKit/Sources/PatataTubeKit/CacheStatistics.swift`.

```swift
public struct CacheStat: Sendable, Identifiable {
    public let id: String          // stable key, e.g. "proxy.hls"
    public let label: String       // "Proxy — HLS segments"
    public let byteCount: Int64
    public let itemCount: Int
    public let budgetBytes: Int64? // nil when the store has no cap
}
```

Rows produced, in display order:

| `id` | Label | Scanned | `itemCount` counts | `budgetBytes` |
|---|---|---|---|---|
| `proxy.hls` | Proxy — HLS segments | `Caches/stream/hls/` | entry directories | nil |
| `proxy.mp4` | Proxy — MP4 ranges | `Caches/stream/mp4/` | entry directories | nil |
| `proxy.total` | Proxy cache total | both of the above | sum of the two counts | `StreamCache.defaultBudgetBytes` (10 GB) |
| `videos.mp4` | Offline videos | `videos/*.mp4` | files | nil |
| `videos.hls` | Offline HLS packages | `videos/hls-*` dirs | packages | nil |
| `videos.covers` | Covers | `videos/*.preview.*`, `videos/poster.*` | images | nil |
| `videos.partial` | Partial downloads | `videos/.downloads/`, `videos/*.resume` | manifest dirs + loose resume files | nil |
| `videos.history` | Download history | `videos/download-completions.json` | 0 or 1 | nil |
| `lists` | Video list cache | `Caches/video-lists/*.json` | files | nil |
| `staging` | Staging temp | `tmp/patatatube-seed-*` | directories | nil |
| `other` | Other files | anything under `videos/` matching no rule | files | nil |
| `total` | Total | every row except `proxy.total` | — | nil |

`other` exists so the rows always reconcile against `total`: an unclassified file
is visible rather than silently missing. `proxy.total` is a derived row shown for
the budget comparison and is excluded from `total` to avoid double counting.

## Collector

```swift
public actor CacheStatisticsCollector {
    public init(
        videosRoot: URL,
        streamRoot: URL,
        videoListRoot: URL,
        tmpRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        proxyBudgetBytes: Int64 = StreamCache.defaultBudgetBytes
    )

    public func collect() -> [CacheStat]
}
```

- One recursive enumeration per root, using
  `FileManager.enumerator(at:includingPropertiesForKeys:)` with
  `.totalFileAllocatedSizeKey` (falling back to `.fileSizeKey` when absent) so the
  reported number matches on-disk allocation.
- A missing root contributes zeroes; it never throws. Unreadable entries are
  skipped.
- Classification of `Documents/videos/` entries lives in a small
  `CacheEntryKind.classify(name:)` helper encoding the same filename conventions
  `CacheManager` already uses (`.mp4` suffix, `hls-` prefix, `.preview.`
  infix, `poster.` prefix, `.downloads` dir, `.resume` suffix,
  `download-completions.json`). Top-level entries are classified once; the walk
  then attributes every descendant's bytes to that entry's kind.
- It is an actor, and `collect()` is therefore called with `await` off the main
  actor, keeping a multi-GB walk off the UI thread.

A separate type rather than a `CacheManager` extension: `CacheManager.swift` is
already ~77 KB, and statistics need none of its mutable state — only its naming
rules, which move into the shared `CacheEntryKind` helper.

`VideoListCache.root` becomes `public` so `AppModel` can hand its path to the
collector.

## UI

`SettingsView` gains a final `Section("Statistics")`.

- Collapsed (default): a single `Button("Calculate")`. No work happens on
  `onAppear` — the walk only runs when explicitly requested.
- While running: the button is replaced by a `ProgressView` and is disabled.
- Done: one `LabeledContent` per `CacheStat`, value formatted
  `"128 files · 42 MB"`, or `"3.4 GB of 10 GB"` appended when `budgetBytes` is
  non-nil. `ByteCountFormatter` with `.file` / binary units. `total` is rendered
  last, bold.
- A "Recalculate" button appears below the results; tapping it re-runs the walk.
- State: `@State private var stats: [CacheStat]?` and
  `@State private var calculating = false`.

No clearing actions, no auto-refresh, no free-disk-space reporting.

## Testing

`ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheStatisticsCollectorTests.swift`:

1. A temp tree containing one entry of every kind with known byte sizes →
   assert each row's `byteCount` and `itemCount`.
2. An unrecognized file in `videos/` → lands in `other`.
3. Rows sum to `total` (excluding the derived `proxy.total`).
4. Non-existent roots → all rows zero, no throw.
5. `proxy.total` carries `budgetBytes == StreamCache.defaultBudgetBytes` and
   equals `proxy.hls + proxy.mp4`.

Filesystem-only; runs under `swift build` / `swift test` in the package, no app
target required. The SwiftUI section itself is covered by the existing manual
checklist in `ios/README.md`.
