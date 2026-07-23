# Inline Video Preparation Spinner

## Goal

MP4 preparation must no longer block the iOS interface with the full-screen
“Preparing…” overlay. Whenever preparation is active for a video, every visible
download control for that video shows the same indeterminate `ProgressView`
spinner used while the player buffers.

This applies whether preparation was initiated by Play, an individual Download,
or a batch download.

## Current Behavior

`VideoGridView` owns a single `preparing` Boolean. Playback and download paths
set it while `VideoStore.ensureReady(id:)` waits for server-side MP4 conversion.
The Boolean presents a blocking overlay over the navigation stack.

`DownloadButton` independently owns the local cache-download lifecycle. Its
loading state renders the determinate circular progress control used after the
MP4 is ready and bytes are being saved locally. It cannot currently observe
preparation initiated by Play.

## Design

### Shared preparation tracker

Add a main-actor observable preparation tracker owned by `VideoGridView` and
provided to its view hierarchy. The tracker records active preparation by video
ID, because server preparation is keyed by video ID rather than local cache
identity.

The tracker supports multiple videos preparing concurrently. Its begin/end
accounting is balanced per video so one operation cannot clear another active
operation’s indicator. Repeated Play actions for a video already preparing are
ignored, preventing duplicate conversion requests while leaving the rest of the
interface interactive.

All calls to `ensureReady(id:)` from `VideoGridView` run through one helper that:

1. Marks the video as preparing.
2. Awaits `ensureReady(id:)`.
3. Clears the preparation state with `defer`, on success, failure, or
   cancellation.

Videos that are already cached or whose server status is already `done` bypass
the tracker because no MP4 conversion occurs.

### Download button rendering

`DownloadButton` observes the shared tracker. Preparation has the highest visual
priority for the matching video ID:

- While preparing, the normal download icon or download progress ring is
  replaced by an indeterminate `ProgressView`.
- The spinner uses the same native SwiftUI control as the buffering state in
  `VideoPlayerView`.
- It retains the download control’s 44-by-44 layout footprint so surrounding
  content does not shift.
- The control is not tappable while preparing and exposes an accessibility label
  of “Preparing video.”

When preparation ends during an individual download, `DownloadButton` naturally
returns to its existing state machine. A successful preparation proceeds to the
existing determinate cache-download ring; a preparation failure returns to the
download icon.

Because the tracker is shared, preparation initiated by Play is reflected in the
download button shown in a grid cell, movie detail screen, or episode row.

### Blocking overlay removal

Remove `VideoGridView`’s `preparing` Boolean and its “Preparing…” overlay. No
replacement overlay or modal is introduced. Navigation and unrelated controls
remain usable while conversion runs.

Batch download controls retain their current batch-level activity behavior. The
episode batch control already uses `ProgressView`; individual video download
buttons additionally show preparation state for the video currently being
converted.

## Data Flow

For playback:

1. The user taps Play.
2. The shared tracker marks that video ID active.
3. Its download button renders the buffering-style spinner.
4. `ensureReady(id:)` completes.
5. The tracker clears the video ID and playback opens.

For download:

1. The user taps Download and the existing download attempt begins.
2. If conversion is required, the tracker marks that video ID active and the
   download button renders the indeterminate spinner.
3. After conversion, the tracker clears the ID.
4. The cache download begins and the button renders its existing determinate
   progress ring.
5. The existing cached checkmark appears after the file lands on disk.

## Errors and Cancellation

Preparation state is always cleared with `defer`.

On preparation failure, the existing store error banner remains the user-facing
error treatment. The download button immediately returns to its idle download
icon. Cache-download errors and cancellation retain their current behavior.

No new retry UI, error type, or server behavior is introduced.

## Testing

Tests will verify:

- The tracker represents independent simultaneous video IDs correctly.
- Balanced begin/end calls do not clear a still-active preparation.
- A matching `DownloadButton` renders an indeterminate `ProgressView`, is not
  tappable, and has the “Preparing video” accessibility label.
- A nonmatching download button retains its normal cache state.
- Download preparation transitions from the spinner to the existing determinate
  cache-download state.
- Failure clears the spinner, restores the download icon, and leaves the
  existing error-reporting path intact.
- Play-triggered preparation drives the matching download button without a
  blocking overlay.

## Non-Goals

- Changing server-side conversion or polling.
- Replacing the determinate local download progress ring.
- Adding conversion percentage reporting.
- Blocking unrelated controls while conversion runs.
