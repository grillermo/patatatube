# iOS Downloads Page Design

## Goal

Add a Downloads page to the iOS app, opened from the existing top-right
ellipsis menu. It shows all active downloads with an aggregate per-download
transfer rate, followed by the three most recently completed downloads.

## User experience

The main grid's ellipsis menu gets a **Downloads** item that pushes a
Downloads screen.

The screen has two sections:

- **In Progress** lists every active download. Each row shows the video title,
  progress, and the aggregate transfer rate for that download beside the
  progress. Rates use `KB/s` below 1 MB/s and `MB/s` at or above it. Until a
  rate can be measured, the row says `Calculating…`. A Cancel control invokes
  the same cancellation behavior used today.
- **Recently Completed** shows at most three cached downloads, ordered by
  completion time with the newest first. Tapping a row plays its existing local
  file.

Sections with no items are omitted. Completed-history entries whose local file
has been removed are discarded, so each displayed row can be played.

Failed and explicitly cancelled transfers leave the active section and retain
the app's current error and cleanup behavior.

## Architecture

`CacheManager` remains the single owner of transfer lifecycle, progress,
cancellation, resumption, and local files. It gains an observable activity
snapshot for each active video/version containing:

- cache identity and progress;
- cumulative transferred bytes and known total byte count, when available;
- a rate derived from the elapsed time and change in the aggregate byte total.

For segmented transfers, each delegate update contributes to that download's
one aggregate byte total. The exposed rate is therefore per video download,
not per segment or app-wide.

A small persisted completion-history record stores successful video/version
identities and their completion timestamps. On success, the manager appends
the entry, sorts newest first, and keeps three. Existing cached files that
predate this feature do not need synthesized history entries.

The Downloads view resolves activity and history identities against the live
video store for display. It receives closures from `VideoGridView` to cancel a
download through `CacheManager` and to start existing local playback. No
second download coordinator or network path is introduced.

## Verification

Add focused tests for aggregate byte-rate calculation (including segmented
downloads), rate formatting, completion history ordering and its three-item
limit, cancellation delegation, and Downloads screen rendering for active,
completed, and empty states.
