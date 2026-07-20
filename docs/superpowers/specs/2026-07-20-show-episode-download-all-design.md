# Show Episode Download-All Design

## Goal

Add a **Download all** control to the episode list for a single TV show. The control downloads only that show's eligible episodes, one at a time, in the order shown.

## Scope

This iteration keeps the batch behavior local to `EpisodesView`. It does not refactor the existing global download-all flow or introduce a shared batch-download coordinator. That extraction is deliberately deferred until the behavior is extended.

## User Experience

- Place a download-all control in the show's top-right navigation toolbar, matching the existing global download-all icon.
- Give the control the accessibility label **Download all episodes**.
- When a batch starts, replace the icon with a spinner and disable the control until the batch finishes.
- Disable the control when the show has no episodes whose current cache state is `.notCached`.
- Keep each episode's existing download control visible and live throughout the batch.
- Allow the active episode download to be cancelled from its row. Cancelling it does not cancel the remaining batch.
- Leaving the episode screen does not cancel an already-started batch, matching the existing global behavior.

## Download Behavior

`EpisodesView` owns a local `downloadingAll` state and a local asynchronous batch routine. At tap time, the routine walks `show.episodes`, whose existing order is season number followed by episode number.

For each episode:

1. Read its current cache state using the episode ID and chosen version ID.
2. Skip it unless the state is exactly `.notCached`; this excludes episodes that are already cached or currently downloading.
3. Await the existing `onDownload(episode)` closure before considering the next episode, ensuring downloads started by this batch never overlap with one another.
4. Continue to the next eligible episode whether the closure returns `true` or `false`.

The batch state is set before iteration and reset with deferred cleanup so the toolbar returns to its idle state after success, failure, or cancellation of an individual episode.

## Existing Integration

The existing `onDownload` closure remains the only path for downloading an episode. It continues to own server-side preparation, URL resolution, cache writes, poster and preview caching, authentication, cancellation detection, and user-visible error reporting.

The existing per-row `DownloadButton` polling observes cache changes made by the batch, so rows display live progress without a new synchronization mechanism.

Because `CacheManager` is not an observable SwiftUI dependency, `EpisodesView` also keeps its toolbar eligibility current with a lightweight, view-lifetime task that periodically rechecks whether any show episode is `.notCached`. Stopping this availability check when the episode screen disappears does not cancel an already-started batch.

## Error Handling

An episode download failure or row-level cancellation returns `false` from `onDownload`. The batch does not abort and proceeds to later eligible episodes. Existing error handling presents the latest non-cancellation failure through the app's error banner. No separate batch summary, retry screen, or cancel-all action is added.

## Test Design

Keep the production implementation local to `EpisodesView`. A small internal batch routine associated with `EpisodesView` will provide a deterministic test seam without becoming a shared app-wide abstraction.

Automated coverage will verify:

- Cached and actively downloading episodes are skipped.
- Eligible episodes start in displayed order.
- The next download does not begin until the previous one completes.
- A `false` result does not prevent later eligible episodes from starting.
- The toolbar control exposes the correct accessibility label.
- The control is disabled while a batch is active and when no episode is eligible.

The existing iOS unit tests and an iOS app build must continue to pass.

## Non-Goals

- A shared global/show batch-download abstraction.
- Parallel episode downloads started by this batch.
- Pause, resume, or cancel-all controls.
- Aggregate batch progress or a completion summary.
- Retrying failed episodes automatically.
- Changing individual episode download controls.
