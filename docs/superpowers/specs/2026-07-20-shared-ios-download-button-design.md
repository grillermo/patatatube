# Shared iOS Download Button Design

**Date:** 2026-07-20
**Status:** Approved, ready for implementation planning

## Goal

Give episode rows the complete download behavior currently implemented by
`MovieDetailView`, while replacing the duplicated controls in
`MovieDetailView`, `VideoCell`, and `EpisodesView` with one tested SwiftUI
component.

The shared control must track live progress, protect newer attempts from stale
async completions, cancel an active attempt, rediscover downloads started
elsewhere, and preserve the cache manager's interruption-resume behavior.

## Scope

The change covers the three existing download controls:

- `MovieDetailView`
- `VideoCell`
- each episode row in `EpisodesView`

`MovieCell` remains a control-free poster link. `CacheManager` remains the sole
owner of download tasks, files, progress, cancellation, and resume data. There
are no backend changes.

## Current State

`MovieDetailView` is the reference implementation. It has:

- an immediate idle-to-loading transition;
- a 44x44 arrow, progress ring, or green checkmark;
- 150 ms polling while downloading and 500 ms polling otherwise;
- tap-to-cancel on the progress ring;
- an attempt UUID that prevents a cancelled or replaced attempt from applying
  a late completion;
- resets when the selected version or audio language changes.

`VideoCell` duplicates most of this logic but lacks the attempt UUID guard.
`EpisodesView` only invokes a synchronous callback and renders a passive
`ProgressView`, so it cannot directly cancel and does not track completion with
the reference behavior.

`CacheManagerTests` already cover cache state, cancellation, and immediate
same-key retry isolation. The application currently has no unit-test target.

## Architecture

### Shared component

Create `ios/PatataTube/Sources/DownloadButton.swift`. It contains:

- `DownloadButton`, the single SwiftUI rendering and interaction surface;
- a small internal state machine for phase, observed cache state, progress,
  and active attempt identity;
- a hashable identity made from video ID, chosen version ID, and audio
  language.

The view receives dependencies instead of reading `AppModel` or `VideoStore`
from the environment:

- a current-cache-state closure;
- an async download closure returning `Bool`;
- a cancellation closure;
- its download identity.

This keeps the component reusable across the three call sites and permits
tests to supply deterministic state and controlled async completions.

### Time dependency

Add `swift-clocks` 1.1.0. The production view uses its continuous clock, while
tests inject `TestClock`. Polling can therefore be advanced deterministically
without real 150 ms or 500 ms waits.

### View inspection

Add `ViewInspector` 0.10.3 only to the new test target. Tests exercise the real
SwiftUI view, including button taps and rendered accessibility output, without
shipping ViewInspector in the application.

Stable accessibility labels and values identify these states:

- idle: Download;
- active: Cancel download, with the clamped percentage as its value;
- complete: Downloaded.

Tests use this public behavior rather than depending on the progress ring's
private shape hierarchy.

## State and Data Flow

### Initial and external state

On appearance, the component immediately reads the supplied cache state. Its
task then polls every 150 ms while the cache reports `.downloading` and every
500 ms otherwise. This discovers downloads started by another surface or by
Download All, and refreshes completion even when the initiating task belongs
elsewhere.

The polling task is tied to the component identity. SwiftUI cancels it when the
view disappears or the identity changes. Disappearance stops observation but
does not cancel the underlying cache download.

### Starting a download

Tapping the idle arrow:

1. creates a unique attempt ID;
2. immediately presents `.downloading(0)` so feedback does not wait for the
   cache poll;
3. awaits the injected download closure;
4. applies the result only if that attempt ID is still active.

A successful current attempt presents the cached checkmark. A failed current
attempt returns to the arrow. `VideoGridView.download` continues to own
preparation and the existing error banner.

### Progress

Observed progress is clamped to `0...1`. The component renders the reference
presentation everywhere: a 30x30 animated ring inside a 44x44 tap target, an
equally sized download arrow, or an equally sized green checkmark.

### Cancelling and retrying

Tapping the active ring:

1. invalidates the active attempt ID before invoking external code;
2. calls the injected cancellation closure once;
3. immediately resets the presentation to the idle arrow.

When the cancelled async call later returns `false`, its invalid attempt ID
prevents it from overwriting a newer attempt. An immediate retry receives a
new attempt ID and is similarly protected from the old task's delegate
callbacks.

### Identity changes

A change to video ID, chosen version ID, or audio language invalidates the
active attempt and resets local observation before polling the new identity.
It does not cancel a download for the old identity. Switching back later
rediscovers that download through `CacheManager.state(for:versionId:)`.

## Resume and Cancellation Semantics

The shared button does not create, read, or remove resume files.

- A network interruption may cause `CacheManager` to persist URLSession resume
  data. A later download tap uses that data and resumes.
- Explicitly tapping the ring calls the current `CacheManager.cancel`, which is
  documented to cancel that attempt and restart from scratch on a later tap.
- The button displays the same idle arrow for both cases because cache state is
  `.notCached`; resume availability remains an internal cache detail.

This preserves the current reference behavior and supersedes the older
tap-to-cancel-resumes wording in the 2026-07-07 progress-ring design.

## Call-Site Integration

### MovieDetailView

Replace its local phase, progress, observed state, attempt ID, effective-state
logic, polling loop, and button renderer with `DownloadButton`. Pass the live
`currentVideo` identity, cache lookup, `onDownload`, and cache cancellation.
The existing version and audio change handlers no longer reset download state;
the shared identity performs that reset.

The Delete cached menu remains local to `MovieDetailView`. After deletion, the
shared poll observes `.notCached`; no deletion API belongs in the button.

### VideoCell

Replace its duplicated state and renderer with `DownloadButton`. Retain the
existing injected cache lookup, async download, and cancellation closures. Its
information sheet reads the cache state independently and does not own button
state.

### EpisodesView and ShowsView

Change the propagated download callback from `(Video) -> Void` to
`(Video) async -> Bool`. Each episode supplies its ID/version/audio identity,
cache lookup, async callback, and cache cancellation to `DownloadButton`.

The row's play gesture remains unchanged. The button consumes its own tap so a
download or cancel action does not start playback.

### VideoGridView

Pass `await download(video)` through the show/episode path, matching the
existing movie-detail and video-cell paths. The private `download` function
continues to prepare videos, update `VideoStore`, invoke `CacheManager`, and
report errors.

## Testing

Add a `PatataTubeTests` unit-test target through XcodeGen and include it in the
shared scheme. Use Swift Testing, `@testable import PatataTube`, ViewInspector,
and Clocks.

Automated button coverage includes:

- idle arrow, active ring/percentage, and cached checkmark output;
- progress clamping below zero and above one;
- immediate loading feedback after tapping Download;
- success and failure completion;
- external transitions into downloading, cached, and not cached;
- deterministic 150 ms active and 500 ms inactive polling;
- cancel callback invoked exactly once per tap;
- late completion ignored after cancellation;
- immediate retry protected from the first attempt's late completion;
- identity change invalidating an outstanding completion and restarting
  observation;
- view disappearance stopping polling without invoking cancellation.

Keep the complete `PatataTubeKit` suite green, including cancellation and
same-key retry tests. Update `ios/README.md` so manual verification covers
matching progress, cancel, retry, completion, and tap isolation in
`MovieDetailView`, `VideoCell`, and `EpisodesView`.

Verification runs the generated iOS unit-test scheme on a simulator and the
standalone `PatataTubeKit` test suite.

## File Changes

- Create `ios/PatataTube/Sources/DownloadButton.swift`.
- Create `ios/PatataTube/Tests/DownloadButtonTests.swift`.
- Modify `ios/PatataTube/Sources/MovieDetailView.swift`.
- Modify `ios/PatataTube/Sources/VideoCell.swift`.
- Modify `ios/PatataTube/Sources/EpisodesView.swift`.
- Modify `ios/PatataTube/Sources/ShowsView.swift`.
- Modify `ios/PatataTube/Sources/VideoGridView.swift`.
- Modify `ios/PatataTube/project.yml`.
- Modify `ios/README.md`.
- Regenerate the Xcode project and Swift package resolution artifacts.

## Acceptance Criteria

- All three existing download surfaces use the same `DownloadButton` type and
  44x44 presentation.
- A download started anywhere displays live progress on every visible matching
  surface.
- The active ring cancels the matching cache task and immediately returns to
  the arrow.
- Interrupted downloads remain resumable; explicitly cancelled downloads
  restart according to `CacheManager`'s current contract.
- A stale completion cannot overwrite a cancel, retry, or identity change.
- Episode download/cancel taps do not trigger playback.
- New button tests, existing cache tests, and the iOS build pass.
