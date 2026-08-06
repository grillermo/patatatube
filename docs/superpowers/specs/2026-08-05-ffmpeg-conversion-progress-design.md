# ffmpeg conversion progress — design

Date: 2026-08-05

## Problem

While the server converts a library video, the iOS download button shows a bare
indeterminate spinner. A 40-minute movie can sit there for ten minutes with no
sign of whether anything is happening or how far along it is. Conversions do not
appear in the Downloads view at all — a `DownloadActivity` row is only created
once the byte transfer starts, and `VideoStore.ensureReady` blocks before that.

## Goal

Show a real percentage for server-side ffmpeg work:

- On each video's download button, a determinate ring with the number inside.
- Queued (not yet started) work keeps the indeterminate spinner — no number.
- A "Converting" section in the Downloads view listing the server's active
  conversion queue, not just work this device started.

Applies to the `convert` and `hls` job kinds. `normalize` (the Twitter/YouTube
download re-encode) is out of scope: those rows show "downloading" in the UI,
not a convert spinner.

## Server

### `ffmpeg_progress.py` (new)

One runner shared by both ffmpeg call sites:

```python
def run_ffmpeg(cmd: list[str], *, duration: float | None = None,
               on_progress: Callable[[float], None] | None = None) -> None
```

- Appends `-progress pipe:1 -nostats` to `cmd` when progress is wanted.
- `Popen` instead of `subprocess.run`; parses `out_time_us=<n>` lines off
  stdout; `pct = out_time_us / (duration * 1_000_000)`, clamped to 0…1.
- Today both call sites merge stderr into stdout to build the `RuntimeError`
  message. Progress needs stdout to itself, so stderr gets its own pipe, drained
  on a thread (otherwise a full stderr pipe deadlocks the stdout read). The last
  ~50 lines are kept for the error message. `-loglevel error` keeps that small.
- `duration=None` or `on_progress=None` → behaves exactly like today's
  `subprocess.run` path, no progress flags. This covers passthrough converts,
  where there is no ffmpeg run at all, and any future call site that has no
  duration.
- Non-zero exit still raises `RuntimeError` with the captured stderr text, so
  `library`'s and `hls`'s existing failure handling is unchanged.

`library._run_ffmpeg` and `hls._run_ffmpeg` are both deleted and replaced by
calls to this. `hls.build_hls_package` already accepts an injected
`run_ffmpeg=` and already computes `_duration(probe)`;
`library.convert_library_video` already has `probe` in hand.

### Database

- `init_db` gains one more idempotent guard: `ALTER TABLE jobs ADD COLUMN
  progress REAL` (schema changes go here as guards, not a migrations
  framework).
- `db.set_job_progress(job_id, value)` — a single UPDATE.
- `db.claim_job` resets `progress` to 0 as part of the claim, so a job requeued
  after a crash restarts its bar rather than resuming a stale number.
- `finish_job` leaves the value alone; finished jobs are not read for progress.

### Throttling

`on_progress` writes to SQLite only when the percentage has advanced by ≥1% or
≥2 seconds have passed since the last write, whichever comes first. A 40-minute
movie produces on the order of 100 UPDATEs, not 100,000.

### Wiring

`converter.run_job` builds `lambda p: db.set_job_progress(job["id"], p)` and
passes it to the handler. `_handle_convert` forwards it as
`convert_library_video(..., on_progress=...)`; `_handle_hls` as
`hls.prepare(..., on_progress=...)` → `build_hls_package`. `_handle_normalize`
is untouched.

The converter is a separate process from the web workers, so SQLite is the only
channel between the two. That is why progress lands on the `jobs` row rather
than being held in memory.

### `GET /api/jobs`

Token-gated like the other API endpoints (`_check_token`). Joins `videos` for
the label so the client needs no second lookup:

```json
{"running": [{"id": 41, "video_id": 812, "version_id": 3, "kind": "convert",
              "progress": 0.47, "title": "…", "show_title": "…"}],
 "queued":  [{"id": 42, "video_id": 813, "version_id": 4, "kind": "convert",
              "progress": null, "title": "…", "show_title": null}],
 "queued_total": 203}
```

`queued` is capped at 20 rows ordered by `priority, id` — the same order
`claim_job` uses, so the list is genuinely the next work up. `queued_total` is
the uncapped count. The cap exists because the bulk Download-all path can leave
200+ jobs queued and this endpoint is polled every 2s.

## iOS

### PatataTubeKit

- `ConversionJob`: `id`, `videoID`, `versionID`, `kind`, `progress: Double?`,
  `title`, `showTitle`. Decoded with the existing `APIClient.makeDecoder()`
  (snake_case conversion), like `Video`.
- `JobsSnapshot`: `running: [ConversionJob]`, `queued: [ConversionJob]`,
  `queuedTotal: Int`.
- `APIClient.jobs() async throws -> JobsSnapshot` — `GET /api/jobs`.
- `JobsStore` (`@MainActor @Observable`): holds the latest snapshot.
  `subscribe()` / `unsubscribe()` maintain a refcount; the 2s poll loop runs
  only while the count is above zero, and stops at zero and on backgrounding.
  Lookups: `progress(videoID:versionID:) -> Double?` and
  `state(videoID:) -> ConversionState?` (`.running(Double)` / `.queued`).
  Clock and API client are injected so it tests without a server.

### Download button

`DownloadButton.control` currently branches on
`preparationTracker?.isPreparing(videoID:)` into a bare `ProgressView()`.

- The condition becomes `isPreparing || jobsStore.state(videoID:) != nil`, so a
  conversion this device did not start also shows.
- `.running(p)` → circular determinate `ProgressView(value: p)` as a ring with
  `Text("\(Int(p * 100))%")` at `.system(size: 11, weight: .semibold)` centered
  inside, all within the existing 44×44 frame.
- `.queued`, or preparing with no job row yet → today's indeterminate spinner,
  unchanged. The swap from spinner to ring is itself the "it started" signal.
- `VideoGridView` subscribes the store for the tab's lifetime.

### Downloads view

A new section above the existing ones:

```
Converting              ← running + queued, from JobsStore
  [thumb] Blade Runner        (47% ring)
  [thumb] Dune                (spinner — queued)
  +183 more
In Progress             ← unchanged, CacheManager byte transfer
Recently Completed      ← unchanged
```

`DownloadActivity` and `CacheManager` are not modified: server conversion and
device transfer stay separate concepts in separate sections. A video does move
from the first section to the second as it progresses, which is accepted.

Rows reuse the existing `thumbnail(_:)`; `video(item.videoID, item.versionID)`
supplies the local row when there is one, and the job's `title` is the fallback
when it is not loaded. The `+N more` footer renders only when
`queuedTotal > queued.count`. The view's existing
`TimelineView(.periodic(by: 0.25))` already redraws; `JobsStore` refreshes the
numbers underneath it every 2s.

## Testing

pytest:

- Progress parser against canned ffmpeg stdout, including a run with no
  duration, interleaved non-progress lines, and malformed values.
- Non-zero exit still raises `RuntimeError` carrying the stderr text now that
  the streams are split.
- `set_job_progress` writes; `claim_job` resets to 0.
- `/api/jobs`: response shape, the 20-row cap, `queued_total` beyond the cap,
  and 401 without a token. Follows the `client` fixture pattern in
  `tests/test_api.py` (reload `db` then `main` after setting env).

swift:

- `JobsStore`: refcount starts and stops the loop, poll cadence on a test clock,
  `progress`/`state` lookups.
- `DownloadButtonTests`: running-with-percent vs queued-spinner render states.
- A `DownloadsView` test covering section contents and the `+N more` footer.
