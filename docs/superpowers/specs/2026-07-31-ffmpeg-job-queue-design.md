# Bounded ffmpeg job queue

**Date:** 2026-07-31
**Status:** approved, not yet implemented

## Problem

On 2026-07-31 at 09:20, `Download all` on the `all` filter spawned 124 concurrent
ffmpeg processes in one minute and took the machine down — other services stopped
answering, ssh would not connect. A retry at 09:31 spawned 54 more and killed it
again.

`VideoGridView.downloadAll()` snapshots every uncached video and fires a task per
video with no bound. Its comment claims "the CacheManager gate bounds how many
actually download at once", but the gate is acquired inside `cache.download`,
*after* `store.ensureReady(id:)` has already called
`POST /api/videos/{id}/prepare`. Prepare calls are therefore unbounded.

Server-side, `router.py` answers each one with:

```python
db.set_library_state(video_id, "converting", version_id=version["id"])
background_tasks.add_task(library.convert_library_video, video_id)
```

`convert_library_video` is sync, so FastAPI runs it in the anyio threadpool
(40 tokens per worker). `./serve` runs `--workers 6`. Ceiling: 240 concurrent
ffmpeg. There were 226 targets, so effectively all of them ran at once.

### Measured cost

One representative job (1080p HEVC → libx264 veryfast) on this machine
(8 cores, 16 GB):

```
1.57 real   5.78 user   0.27 sys
413908992  maximum resident set size
```

= 414 MB RSS and 3.7 cores of demand per process.

| Resource | Demand at 124 procs | Available | Overcommit |
|---|---|---|---|
| RAM | ~51 GB | 16 GB | ~3.2x |
| CPU | ~460 cores | 8 | ~57x |
| Disk read | 226 interleaved streams off one external volume | one bus | thrash |

RAM is what killed it: swap storm on the boot SSD, kernel page-fault stall,
sshd unable to fault in.

There is a second, independent failure mode. Those background tasks occupy the
same anyio threadpool that serves sync route handlers, so the API went
unresponsive before memory ran out — while 226 iOS clients polled
`GET /api/videos/{id}` every 2 seconds against a dead threadpool
(`VideoStore.swift:249`, a loop with no timeout).

### Residue

- 226 library rows still wedged at `converting`. `router.py` early-returns 202
  for those forever, so they will never convert again and clients poll forever.
- 193 orphan `.name.mp4` temp files on `/Volumes/Media`, 6.05 GB. Average 31 MB
  written per job — every job died within seconds of starting.

There are three uncapped ffmpeg spawners in total:
`library.convert_library_video`, `hls.prepare`, and
`downloader._normalize_media_for_ios`.

## Decisions

| Question | Decision |
|---|---|
| Scope | One global budget covering all three ffmpeg spawners |
| Overflow | Durable SQLite queue; drains over hours; survives restart |
| Fairness | Two priority levels — interactive jumps ahead of bulk |
| Cap | 1 concurrent job, `FFMPEG_JOB_LIMIT` env override |
| Crash recovery | Single runner resets orphans at its own startup |

Rejected: a cross-process file-lock semaphore that keeps the BackgroundTasks
(fixes memory, but 226 tasks still hold threads blocked on the lock, so the API
still dies, and a restart still wedges every row). Also rejected: electing one
gunicorn worker to drain, since gunicorn respawns and recycles workers, so
"worker 0" is not a stable identity and the single-owner invariant disappears.

## Architecture

One new process, one new table, three call sites converted from "spawn ffmpeg"
to "enqueue".

### `jobs` table

Added to `db.init_db()` as a `CREATE TABLE IF NOT EXISTS` guard, following the
existing idempotent-migration-runner convention rather than a migrations
framework.

| column | notes |
|---|---|
| `id` | pk, doubles as FIFO order within a priority |
| `kind` | `convert` \| `hls` \| `normalize` |
| `video_id`, `version_id` | target. `version_id` is `0`, never `NULL`, when a kind has no version (see below) |
| `payload` | JSON for kind-specific args (`normalize` input path, `hls` audio_lang) |
| `priority` | int, lower runs first. `0` interactive, `100` bulk |
| `status` | `queued` \| `running` \| `done` \| `failed` |
| `attempts`, `error_msg` | |
| `created_at`, `started_at`, `finished_at` | |

Partial unique index on `(kind, video_id, version_id) WHERE status IN
('queued','running')`, so enqueueing the same work twice is a no-op. This
replaces the comment-heavy race guard currently at `router.py:958`.

`version_id` defaults to `0` rather than `NULL` for kinds that have no version
(`normalize`, and `hls` when no version is specified). SQLite treats `NULL`s as
distinct in a unique index, so a nullable column would silently disable dedup
for exactly those kinds.

Claim is a single atomic statement:

```sql
UPDATE jobs SET status='running', started_at=?, attempts=attempts+1
WHERE id = (SELECT id FROM jobs
            WHERE status='queued' AND attempts < :max_attempts
            ORDER BY priority, id LIMIT 1)
RETURNING *;
```

The `attempts` filter is what keeps a poison job from being reclaimed forever;
a separate sweep marks rows that hit the ceiling as `failed` so they leave the
queue and stop being counted in the depth gauge.

### `converter.py` (new)

The only process in the system that spawns ffmpeg. Boots, resets orphans, then
runs `FFMPEG_JOB_LIMIT` (default 1) worker threads, each looping: claim →
dispatch → record result. Idle poll 1s. Takes `--watch-pid` and exits when the
parent dies, the same contract `caddy_access.py` already uses. Calls
`db.init_db()` at boot (already idempotent and race-safe across processes).

Dispatch targets the existing sync entry points, unchanged:
`library.convert_library_video`, `hls.prepare`,
`downloader._normalize_media_for_ios_sync`.

### Changed modules

- `db.py` — gains `enqueue_job`, `claim_job`, `finish_job`, `reset_orphan_jobs`.
  These know nothing about ffmpeg.
- `router.py` — drops `background_tasks.add_task` at both ffmpeg sites; they
  insert a job row instead and return the same responses.
- `downloader.py` — enqueues a `normalize` job and awaits the row.
- `library.py`, `hls.py` — untouched.

Dependency direction: `converter.py` depends on `db` plus the three job modules;
nothing depends on `converter`. The web tier knows only `enqueue_job`.

## Data flow

### Interactive prepare (tap play, single download button)

```
POST /api/videos/42/prepare  →  probe + plan (unchanged, still to_thread)
  plan.passthrough? → status 'done', no job
  else: set_library_state('converting')
        enqueue_job(kind='convert', video_id=42, priority=0)
        202 {"status":"converting"}
```

Probe and plan stay in the web worker. It is ffprobe, milliseconds, not a
resource risk, and `/prepare` needs the result to answer `done` vs `converting`
synchronously.

### Bulk prepare (`downloadAll`)

Identical, `priority=100`. The client signals it: `PrepareRequest` gains an
optional `priority: "bulk"` field, and `VideoStore.ensureReady` gains a
`bulk: Bool = false` parameter that `downloadAll` passes as `true`. Anything
omitting the field is interactive.

If the iOS change ships later than the server change, the server is still fully
correct — every job is priority 0 and the queue is plain FIFO. Priority is an
optimization layered on a queue that is safe without it.

### HLS

`GET /videos/42/hls/master.m3u8` on a cold package enqueues `kind='hls'`,
priority 0, and returns 409 as it does today. The client already polls the
master URL; nothing changes there.

### Normalize

`download_video` enqueues `kind='normalize'` with the temp path in `payload`,
then awaits the job row (async poll, 1s — it runs as a BackgroundTask on the
event loop, so this holds no thread). Job completion writes the output path back
into the row; the downloader moves it to `videos/{id}.mp4` as it does now.

### Runner loop

```
boot    → reset_orphan_jobs(): 'running' → 'queued', unlink each job's temp
loop    → claim_job(); none? sleep 1s
          run it; finish_job(done|failed)
SIGTERM → stop claiming; terminate live ffmpeg; requeue; unlink temps; exit
```

The single-owner invariant is what makes the boot reset correct: if the runner
is starting, nothing else can hold a job.

### Row-status contract is unchanged

`videos.status` / `video_versions.status` still go
`unconverted → converting → done`; failures still revert to `unconverted` with
`error_msg`; rows are still never deleted. The `jobs` table is internal
bookkeeping. The iOS app's polling and `serialize_video` need no changes. A
queued job means a row sits at `converting` longer, which is honest.

## `./serve`

A supervised child is added next to `caddy_access.py`, spawned before the web
server so the queue table exists and the runner is draining by the time requests
land:

```bash
# The converter is the only process that spawns ffmpeg; the web workers just
# enqueue. Respawn on crash — unlike gunicorn's workers, a bare background
# child that dies would stall the queue silently.
( until "$PYTHON_BIN" -u converter.py --watch-pid "$$"; do sleep 1; done ) 2>&1 \
  | colorize 31 convert >&3 &
```

`$$` survives the later `exec` into uvicorn or gunicorn, so `--watch-pid` works
in both the DEV and production paths, exactly as the existing `caddy_access.py`
line does.

In DEV, `--reload` restarts uvicorn but **not** the converter. Editing
`converter.py` or `library.py` requires a full `./serve` restart. This is
documented, not solved — watchfiles for one dev-loop convenience is not worth
the dependency.

## Error handling

- **ffmpeg fails / source missing** — job → `failed` with `error_msg`, version
  reverts to `unconverted`, temp unlinked. Byte-for-byte today's behavior,
  relocated out of the `except` block in `convert_library_video`.
- **Runner crashes mid-job** — the respawn wrapper restarts it; the boot reset
  requeues the job and unlinks its temp.
- **Poison job** — `attempts` increments at claim time, and the claim query
  skips rows at `MAX_JOB_ATTEMPTS` (3), which a sweep then marks `failed`.
  Without this, the respawn wrapper turns one bad file into an infinite crash
  loop.
- **SIGTERM** — stop claiming, terminate live ffmpeg, requeue, unlink temps,
  exit. A restart mid-drain loses no queue state.
- **DB contention** — nothing new needed. `_conn()` already sets WAL and
  `busy_timeout=30000`, and claim is a single atomic statement.

No automatic retry of failed jobs. Today's code has none, and adding it would
re-run expensive work on permanently broken sources.

Queue depth is unbounded. 226 rows is not a problem, and a depth cap would
reintroduce the "download all silently drops most videos" behavior the durable
queue exists to avoid.

## Observability

Mirroring the existing `[stream] +1 <file> active=N/16` gauge in
`log/backend.log`:

```
[job] +1 kind=convert id=812 priority=100 queued=225
[job] -1 kind=convert id=812 status=done secs=412
```

Queue depth becomes readable at a glance — the thing that was missing while this
incident was being debugged.

## Testing

Queue logic is pure SQLite with no ffmpeg in it, so most of this is fast unit
tests. Follow `tests/test_db.py` conventions for table ops and `tests/test_api.py`'s
`client` fixture (reload `db` then `main` after setting `DB_PATH`) for endpoints.

**`tests/test_jobs.py`** (new):

- `claim_job` returns highest priority first, FIFO by `id` within a priority
- claim is exclusive: two claims against one queued row yield one job and one
  `None` — the actual concurrency guarantee, asserted directly rather than
  trusted by eye
- enqueueing a duplicate `(kind, video_id, version_id)` while queued or running
  is a no-op; enqueueing again after `done` is allowed
- `reset_orphan_jobs` requeues `running` rows and unlinks their temps
- a job at `MAX_JOB_ATTEMPTS` is never claimed, and the sweep marks it `failed`

**`tests/test_converter.py`** (new), with `run_ffmpeg` faked the way
`hls.build_hls_package` already accepts an injected `run_ffmpeg`:

- success path writes `done` and the version row goes to `done`
- ffmpeg raising leaves the version at `unconverted` with `error_msg` and
  unlinks the temp
- **the cap holds**: with `FFMPEG_JOB_LIMIT=1` and N queued jobs, a fake
  `run_ffmpeg` that records concurrent entries never sees two at once. This is
  the regression test for the incident.

**`tests/test_api.py`** additions:

- `/prepare` enqueues instead of spawning, still returns 202, still sets
  `converting`
- passthrough still short-circuits to `done` with no job row
- 226 rapid `/prepare` calls produce 226 queued jobs and zero ffmpeg invocations
  from the web process
- cold `master.m3u8` enqueues an `hls` job and still 409s

Async tests need `@pytest.mark.asyncio` individually — there is no global
asyncio mode.

**Not automated:** the `./serve` respawn wrapper and `--watch-pid` teardown,
same as the existing `caddy_access.py` child. Verified by hand: kill the
converter, confirm it comes back; kill `./serve`, confirm the converter exits.

## Cleanup this change enables

Not part of the implementation, but unblocked by it:

- Reset the 226 wedged rows to `unconverted` (both `videos` and
  `video_versions`). After this change, the runner's boot reset prevents the
  wedge from recurring, but it does not clean up rows wedged by the old code
  path, since those have no `jobs` row.
- Delete the 193 orphan temp files (6.05 GB).

## Out of scope

Tracked separately, from the same incident:

- Capping `ffmpeg -threads` per job (each job currently demands 3.7 cores).
- Moving `ensureReady` inside the iOS download gate so
  `SimultaneousDownloadSettings` actually bounds prepare calls. With this
  server-side queue in place that is a client-responsiveness fix, no longer a
  server-safety one.

## Verification

Reset the wedged rows, hit `Download all`, then watch `log/backend.log` show
`queued=` counting down with exactly one ffmpeg alive in `ps` and the machine
staying responsive.
