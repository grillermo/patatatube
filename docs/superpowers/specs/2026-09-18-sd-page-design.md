# `/sd` — random-shuffle player for an iPad 1 (iOS 5.1.1)

**Date:** 2026-09-18
**Status:** design approved, pending implementation plan

## Goal

A page at `/sd` that plays one video at a time from a selectable group, in
shuffled order, advancing on its own when a video ends. It must work on a
first-generation iPad running iOS 5.1.1 over plain HTTP on the LAN. The
selected group lives in the backend, and defaults to **"videos musicales"**
(group `name = 'children'`, id 1, 39 done downloads as of this date), whose
SD renditions are produced by a one-off backfill so it is playable on day one.

## Constraints that drive the design

- **Decoder.** The iPad 1 decodes H.264 only up to 720p30, Main profile, level
  3.1. Stored files are 1080p High-profile passthroughs or `-profile:v high`
  re-encodes (`downloader._video_codec_args`, `library._REENCODE_VIDEO_ARGS`),
  so none play. A separate SD rendition is required.
- **Browser.** Mobile Safari 5.1: ES5 syntax, `XMLHttpRequest`, `JSON`,
  `addEventListener`. No `fetch`, `Promise`, `URLSearchParams`, `<dialog>`,
  CSS grid/flex/`aspect-ratio`, service workers or IndexedDB. The existing SSR
  page is unsuitable; `/sd` gets its own template and script.
- **Autoplay.** iOS 5 needs a user tap before the first `play()`. A `<video>`
  element that has been tapped once may be re-pointed at a new `src` and
  `play()`ed from an `ended` handler; a freshly loaded page may not. So the
  page must advance **in place**, never by reloading.
- **Network.** iOS 5 cannot complete a TLS handshake with the public host
  (no ISRG root, no AEAD-only cipher overlap). It uses
  `http://<mac-lan-ip>:3050`, which Caddy already serves in plain HTTP. The
  login cookie is already non-`Secure` over HTTP (`router.py`, `secure=scheme ==
  "https"`).
- **ffmpeg invariant.** Only `converter.py` spawns ffmpeg, so the SD encode is
  a new job kind, not a BackgroundTask.

## Scope

In: download rows (`source != 'library'`) in groups. Out: Plex library rows
(TV/Movies are not groups), HLS, resume positions, uploads, any change to the
existing SSR page or iOS app.

## 1. SD rendition

- **File:** `VIDEOS_DIR/{id}.sd.mp4`, next to the original.
- **Encode** (always re-encode, never copy):
  `-c:v libx264 -preset veryfast -crf 23 -profile:v main -level 3.1
  -pix_fmt yuv420p -vf "scale='min(1280,iw)':-2" -r 30 -maxrate 2.5M
  -bufsize 5M -c:a aac -b:a 128k -ac 2 -movflags +faststart`.
  The bitrate cap protects the A4 decoder and the iPad's Wi-Fi.
- **Atomic write:** encode to `{id}.sd.mp4.part` (with `-f mp4`), then
  `os.replace` into place, then set the flag. A half-written file is never
  served or marked ready.
- **Job kind `sd`** in `converter.py`'s `JOB_HANDLERS`, running through
  `ffmpeg_progress.run_ffmpeg` with the source duration, so it reports progress
  like `convert`/`hls`. It flushes the response cache after each job, like every
  other job does. The existing `idx_jobs_pending` unique index already
  de-duplicates `(kind='sd', video_id, 0)`.
- **Readiness column:** `videos.sd_ready INTEGER NOT NULL DEFAULT 0`, added by an
  idempotent `ALTER TABLE` guard in `db.init_db`. Set to 1 by the job on
  success. A missing source file, or an ffmpeg failure, fails the job and leaves
  the flag at 0. The row is never deleted.
- **Priorities:** background SD work enqueues at `priority=200`, behind
  interactive work (0) and iOS Download-all (100). The one-off backfill
  (§4) uses `priority=50`.
- **What gets enqueued:**
  - Selecting a group on `/sd` enqueues every `done`, non-library row in it with
    `sd_ready = 0`.
  - A download finishing (`status → done`) in the currently selected `/sd`
    group enqueues it.
  - The backfill script (§4).
- **Cleanup:** `api_delete_video` (download branch) and `promote.promote` also
  `unlink(missing_ok=True)` `VIDEOS_DIR/{id}.sd.mp4`.
- **Serving:** `GET /videos/{id}/sd.mp4`.
  - Caddy: a disk-served rule mirroring the existing `/videos/{id}/stream`
    handler (`@ptunauth` → 401, `try_files /videos/{id}.sd.mp4`, immutable
    cache header).
  - FastAPI fallback route with the same token/cookie check and Range support,
    reusing `_parse_byte_range` / `_iter_file_range` and the stream semaphore.
    It returns 404 unless `sd_ready`.
  - The Caddyfile lives outside this repo (`~/c/server/Caddyfile`), so its edit
    is a separate change, reloaded by hand.

## 2. Backend-remembered selection and shuffle

New single-row table, created in `db.init_db`:

```sql
CREATE TABLE IF NOT EXISTS sd_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    group_id INTEGER,
    current_id INTEGER,
    played TEXT NOT NULL DEFAULT '[]'   -- JSON list of video ids played this round
);
```

**Default:** `init_db` inserts the row (`INSERT OR IGNORE`, id=1) with
`group_id` = the id of the group whose `name = 'children'`, or NULL when no such
group exists (test databases). An existing row is never touched, so a group
picked later survives restarts.

**Shuffle** (`sd.py`, pure functions over `db` helpers):

- *Candidates* = rows in `group_id` with `status='done'`, `source != 'library'`,
  `deleted_at IS NULL`, `sd_ready = 1`.
- `next_video()`: pick uniformly at random from candidates not in `played`,
  excluding `current_id`. If that set is empty, reset `played` to `[]` and pick
  from candidates excluding `current_id`, falling back to `current_id` itself
  when it is the group's only candidate. Append the pick to `played`, set
  `current_id`, return it. Return None when there are no candidates.
- `current_video()`: `current_id` if it is still a candidate, else
  `next_video()`.
- `select_group(group_id)`: set `group_id`, clear `current_id` and `played`,
  enqueue missing SD jobs.

Because the order is never stored, the shuffle handles changes to the group:
a video that becomes `sd_ready` joins the current round, and a deleted or moved
one stops being a candidate.

## 3. Endpoints and page

All in `router.py`, logic delegated to `sd.py`. Auth for `GET /sd` matches `/`:
the login cookie, with a 303 to `/login?next=/sd` without it.

| Route | Behaviour |
|---|---|
| `GET /sd` | Renders `views/templates/sd.html`: group `<select>` in a POST form, and either the player for `current_video()` or a status message. Added to `middleware._NEVER_CACHED_PATHS`. |
| `POST /sd/group` | Form field `group_id`. `select_group`, then 303 to `/sd`. 404 for an unknown group. |
| `POST /sd/next` | Advances the shuffle. With `Accept: application/json` (the script) returns `{id, title, src}`, or 204 when the group has no candidates. Otherwise (the no-JS **Next** button) 303 to `/sd`. |

`POST /sd/group` and `POST /sd/next` accept the login cookie or Bearer. They are
POSTs because they mutate state, and a GET would be served from the response
cache. The existing mutating-request flush covers them.

**Page states:**

1. No group selected: only the selector.
2. Group has videos but none SD-ready: "Preparing N of M…" plus
   `<meta http-equiv="refresh" content="30">`. This is safe because nothing is playing.
3. Group has no eligible videos: "No videos in this group."
4. Playing: `<video id="player" controls src="/videos/{id}/sd.mp4">`, title
   below, **Next** button (form POST to `/sd/next`).

**Script** (inline, ES5):

- On `ended` → `XMLHttpRequest` `POST /sd/next` with `Accept: application/json`
  → set `player.src`, `player.load()`, `player.play()`, update the title.
- On `error` → the same advance. After **3 consecutive** failures, stop and
  show "Can't play videos in this group"; a successful `playing` event resets
  the counter.
- A 204 or network failure shows a message, with no retry loop.
- The first video needs one tap (iOS 5 policy). After that, playback continues
  unattended.

**CSS:** block layout only, black background, `video { width:100%; height:
<fixed px> }`, no grid/flex/`aspect-ratio`/`env()`/`calc()`.

## 4. One-off backfill

`sd_backfill.py <group-name>`: resolves the group by `name`, enqueues an `sd`
job at `priority=50` for every eligible row with `sd_ready = 0`, and prints how
many it queued and skipped. Running it twice is harmless (unique pending index plus
`sd_ready`). After deploying, run it once:

```bash
python sd_backfill.py children   # "videos musicales", 39 videos
```

Progress shows in `log/backend.log` as `[job] +1 kind=sd …` / `-1`. Rough
estimate: 15–30 min at `FFMPEG_JOB_LIMIT=2`.

## 5. Deployment outside the code

- `.env`: append the Mac's LAN IP to `ALLOWED_HOSTS`. The default list's
  `192.168.1.1` is likely the router.
- `~/c/server/Caddyfile`: the `sd.mp4` disk rule (§1), then reload Caddy.
- Restart `./serve` fully: `converter.py` does not pick up code under `--reload`.
- On the iPad: `http://<mac-lan-ip>:3050/login`, then `/sd`.

## 6. Error handling summary

| Failure | Result |
|---|---|
| SD encode fails / source missing | Job `error`, `sd_ready` stays 0, video never offered |
| SD file deleted from disk behind our back | Caddy misses → FastAPI 404 → page `error` → skip (counts toward 3) |
| Selected group deleted | No candidates → state 3 |
| Media volume unmounted | Existing `ensure_media_root` refuses to start |

## 7. Testing

pytest, following the `client` fixture pattern (reload `db` then `main` after
setting env), `MEDIA_ROOT=.`:

- **Shuffle** (`tests/test_sd.py`): every candidate plays exactly once before
  any repeat, a round reset never repeats `current_id`, a single-candidate
  group repeats itself, a newly `sd_ready` video joins the current round,
  deleted/moved and not-ready rows are never picked, and `select_group` clears
  state.
- **Default seed:** `init_db` seeds `children` when present, NULL when absent,
  and never overwrites an existing selection.
- **Endpoints:** `/sd` login redirect, each page state, `/sd/group` enqueues
  jobs and 404s unknown groups, `/sd/next` JSON vs 303 vs 204, and `/sd` is
  never cached.
- **Job:** the `sd` handler with ffmpeg mocked writes via `.part` + replace,
  sets `sd_ready`, and leaves it 0 on failure. The download-done hook enqueues
  only for the selected group.
- **Cleanup:** delete and promote remove `{id}.sd.mp4`.
- **Backfill:** it queues eligible rows at priority 50, and a second run
  queues nothing.
- **Manual:** on the iPad, the first tap plays, then three consecutive videos
  advance unattended and the group switch takes effect.
