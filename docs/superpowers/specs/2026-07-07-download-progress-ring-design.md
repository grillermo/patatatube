# Download Progress Ring — Design

**Date:** 2026-07-07
**Status:** Approved, ready for implementation plan

## Goal

The offline-download button in the iOS app's `VideoCell` currently shows an
indeterminate spinner while a video caches. Replace it with a **filling ring
(donut)** that tracks real download percentage 0→100%. Tapping the ring cancels
the download.

## Background — current state

- `CacheManager` (PatataTubeKit) already computes real byte progress in
  `inFlight[key]`, updated in the `didWriteData` delegate callback, and exposes
  it via `state(for:) -> CacheState.downloading(Double)`.
- Nothing **publishes** those updates: `VideoGridView` reads
  `cache.state(for:)` only at render time, and `VideoCell` ignores the `Double`,
  rendering an indeterminate `ProgressView()` driven by a local `downloadPhase`
  enum (`.idle / .loading / .done`).
- Server side: `GET /videos/{id}/stream` full-file branch already sends
  `Content-Length: file_size` (main.py:424), so `totalBytesExpectedToWrite` is
  valid and real percent is available. **No backend change.**

## A download can start two ways — both must animate

1. **Tap the cell's own button** → flows through the cell's `onDownload` closure.
2. **"Download all"** (`VideoGridView.download`, ~line 197) or **re-entering the
   grid** while a download runs → progress lives only in
   `CacheManager.inFlight`; the cell renders `.downloading(x)` once and never
   updates.

The chosen approach reads `cache.state(for:)` as the single source of truth, so
all start paths animate uniformly.

## Approach — poll `cache.state(for:)` from the cell

Rejected alternatives:
- **Progress callback through `onDownload`** — elegant for taps, but download-all
  and re-entry don't flow through the cell's closure, so those rings freeze.
- **CacheManager as `@Published`/AsyncStream observable** — it's a background
  `URLSessionDelegate` (`@unchecked Sendable`); making it MainActor-observable
  fights delegate threading and re-renders the whole grid per byte. Overkill.

## Components

### 1. Ring view (`VideoCell`)

Replace the `.downloading` branch's `ProgressView()` with a tappable ring:

```swift
Button { onCancel() } label: {
    ZStack {
        Circle().stroke(.gray.opacity(0.25), lineWidth: 4)
        Circle().trim(from: 0, to: progress)
            .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.15), value: progress)
    }
    .frame(width: 30, height: 30)
    .frame(width: 44, height: 44)   // keep existing tap target
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

- Empty center (no percent text, no icon).
- 30×30 ring inside the existing 44×44 tap frame.

### 2. Progress feeding

`VideoCell` gains `@State private var progress: Double = 0`. A `.task` loop runs
while the effective state is `.downloading`:

```swift
while !Task.isCancelled {
    if case .downloading(let p) = effectiveState { progress = p } else { break }
    try? await Task.sleep(for: .milliseconds(150))
}
```

- Source of truth stays `cache.state(for:)` (via the parent-supplied
  `cacheState` / `effectiveState`), so tap / download-all / re-entry all animate.
- Loop self-cancels when SwiftUI tears down the `.task` (state leaves
  `.downloading`).

### 3. Cancel path (`CacheManager`)

Add a key→task map (`tasksByKey: [String: URLSessionDownloadTask]`) alongside the
existing `idByTask`, populated where the task is created and cleared in `finish`.
New method:

```swift
public func cancel(id: Int, versionId: Int? = nil) {
    // look up task by cacheKey; task.cancel(byProducingResumeData:) —
    // reuses existing resumeData persistence + didCompleteWithError failure path
}
```

- Cancel makes the awaiting `download` throw → `onDownload` returns `false` →
  cell's `downloadPhase` goes `.idle` → ring reverts to `arrow.down.circle`.
- Resume data is persisted (existing `persistResumeData`), so a later tap resumes.

### 4. Wiring

- `VideoCell` gains `let onCancel: () -> Void`.
- `VideoGridView` passes
  `onCancel: { model.cache.cancel(id: video.id, versionId: video.chosenVersionId) }`.

### 5. Local phase reconciliation

Current `.loading` phase maps to `.downloading(0)` in `effectiveState` — keep it
as instant tap feedback before the first byte tick; the poll loop overwrites
`progress` as real data arrives. `effectiveState` otherwise unchanged.

## Testing

- **PatataTubeKit** (`swift build` + test target): unit tests for
  `CacheManager.cancel` — in-flight task cancels, resume data written, state
  returns to `.notCached`.
- **Ring / poll UI**: visual, verified manually per `ios/README.md` (no iOS UI
  test target exists).

## Out of scope

- No backend change.
- No indeterminate fallback — server guarantees `Content-Length`.
- No new dependencies.
