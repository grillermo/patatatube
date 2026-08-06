# Bounded ffmpeg Job Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the web tier stop spawning ffmpeg, so no user action can spawn more than `FFMPEG_JOB_LIMIT` (default 1) concurrent ffmpeg processes.

**Architecture:** A `jobs` table in the existing SQLite DB is the durable queue. A new single-purpose process, `converter.py`, is the only thing in the system that spawns ffmpeg; it claims jobs atomically and runs `FFMPEG_JOB_LIMIT` at a time. Every current ffmpeg call site in the web tier (`/prepare`, audio-change reconversion, cold `master.m3u8`, download normalization) becomes an `enqueue_job` call, which also frees the anyio threadpool that ffmpeg was starving.

**Tech Stack:** Python 3.13, FastAPI, SQLite (3.53, WAL mode), gunicorn + uvicorn workers, pytest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md`

## Global Constraints

- No new third-party dependencies. Everything here uses the stdlib plus what is already in `requirements.txt`.
- `FFMPEG_JOB_LIMIT` defaults to **1**. `MAX_JOB_ATTEMPTS` defaults to **3**. Both env-overridable, read via the existing `_positive_int_env` pattern in `router.py:77` or a local equivalent.
- Priority constants: `PRIORITY_INTERACTIVE = 0`, `PRIORITY_BULK = 100`. Lower runs first.
- Job kinds are exactly `"convert"`, `"hls"`, `"normalize"`.
- `version_id` is `0`, never `NULL`, when a kind has no version. SQLite treats `NULL`s as distinct in a unique index, which would silently disable dedup for those kinds.
- **The row-status contract does not change.** `videos.status` / `video_versions.status` still go `unconverted → converting → done`; failures still revert to `unconverted` with `error_msg`; rows are still never deleted. The `jobs` table is internal bookkeeping — `serialize_video` and the iOS polling loop must keep working untouched.
- Schema changes go into `db.init_db()` as idempotent `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` guards. This repo has no migrations framework and is not getting one.
- Tests that are `async def` need `@pytest.mark.asyncio` individually — there is no global asyncio mode and no `pytest.ini`.
- Run tests with `python -m pytest`. The venv is `python_env/`.

### Three refinements to the spec, decided while writing this plan

1. The spec says job completion "writes the output path back into the row" but its column list has nowhere to put it. Added a **`result`** TEXT (JSON) column.
2. The spec calls claim "a single atomic statement". A lone `UPDATE ... WHERE id = (SELECT ...)` in a *deferred* transaction can fail with `SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` does **not** retry. Task 1 adds a `_write_conn()` helper that issues `BEGIN IMMEDIATE`, so concurrent claimers serialize on `busy_timeout` instead of erroring.
3. Orphan temp cleanup needs to know a `convert` job's temp path without re-deriving it. Task 2 adds `library.temp_target_for(video_id)`, and `convert_library_video` is refactored to call it, so there is one definition rather than two.

---

## File Structure

**Create:**
- `converter.py` — the runner process. Claim loop, worker threads, orphan reset, signal handling, `[job]` gauge. No ffmpeg command construction of its own; it dispatches to existing modules.
- `tests/test_jobs.py` — queue semantics (pure SQLite, no ffmpeg).
- `tests/test_converter.py` — runner loop with `run_ffmpeg` faked.

**Modify:**
- `db.py` — `jobs` DDL in `init_db()`, `_write_conn()` helper, seven queue functions. Knows nothing about ffmpeg.
- `library.py` — extract `temp_target_for()`; `convert_library_video` uses it.
- `router.py` — `/api/videos/{id}/prepare`, `/api/videos/{id}/audio`, and `hls_asset` enqueue instead of `background_tasks.add_task`. `PrepareRequest` gains `priority`.
- `downloader.py` — `_normalize_media_for_ios` enqueues and awaits instead of `asyncio.to_thread`.
- `serve` — spawn the supervised converter child.
- `CLAUDE.md` — document the `convert` log label and the queue.
- `tests/test_api.py`, `tests/test_downloader.py` — updated expectations.
- `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`, `VideoStore.swift`, `ios/PatataTube/Sources/VideoGridView.swift` — bulk priority signalling.

**Dependency direction:** `converter.py` depends on `db`, `library`, `hls`, `downloader`. Nothing depends on `converter`. The web tier knows only `db.enqueue_job`.

---

### Task 1: Job queue in `db.py`

The whole queue, with no runner and no callers yet. Pure SQLite — fast to test and the foundation everything else consumes.

**Files:**
- Modify: `db.py` (add after the existing `_conn` at `db.py:11-27`; DDL inside `init_db` at `db.py:42`)
- Test: `tests/test_jobs.py` (create)

**Interfaces:**
- Consumes: `db._conn`, `db.init_db` (existing).
- Produces, all in `db`:
  - `JOB_KINDS: tuple[str, ...]` = `("convert", "hls", "normalize")`
  - `PRIORITY_INTERACTIVE: int` = `0`, `PRIORITY_BULK: int` = `100`
  - `MAX_JOB_ATTEMPTS: int` (env `MAX_JOB_ATTEMPTS`, default 3)
  - `enqueue_job(kind: str, video_id: int, version_id: int = 0, priority: int = PRIORITY_INTERACTIVE, payload: dict | None = None) -> int | None` — returns the new job id, or `None` if an equivalent job is already queued/running.
  - `claim_job() -> dict | None` — atomically marks the next eligible job `running` and returns it. `payload` comes back as a parsed `dict`.
  - `finish_job(job_id: int, status: str, error_msg: str | None = None, result: dict | None = None) -> None`
  - `requeue_job(job_id: int) -> None` — back to `queued`, clears `started_at`.
  - `reset_orphan_jobs() -> list[dict]` — requeues every `running` row, returns them so the caller can clean temps.
  - `sweep_exhausted_jobs() -> int` — marks `queued` rows at `MAX_JOB_ATTEMPTS` as `failed`, returns how many.
  - `queued_job_count() -> int`
  - `get_job(job_id: int) -> dict | None`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_jobs.py`:

```python
# tests/test_jobs.py
import pytest


@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


def test_enqueue_returns_id_and_claim_returns_the_job(tmp_db):
    job_id = tmp_db.enqueue_job("convert", video_id=42, version_id=7)
    assert job_id is not None

    job = tmp_db.claim_job()
    assert job["id"] == job_id
    assert job["kind"] == "convert"
    assert job["video_id"] == 42
    assert job["version_id"] == 7
    assert job["status"] == "running"
    assert job["attempts"] == 1


def test_claim_returns_none_when_queue_empty(tmp_db):
    assert tmp_db.claim_job() is None


def test_payload_round_trips_as_a_dict(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1, payload={"input_path": "/tmp/a.mkv"})
    job = tmp_db.claim_job()
    assert job["payload"] == {"input_path": "/tmp/a.mkv"}


def test_priority_beats_insertion_order(tmp_db):
    bulk = tmp_db.enqueue_job("convert", video_id=1, priority=tmp_db.PRIORITY_BULK)
    interactive = tmp_db.enqueue_job("convert", video_id=2, priority=tmp_db.PRIORITY_INTERACTIVE)

    assert tmp_db.claim_job()["id"] == interactive
    assert tmp_db.claim_job()["id"] == bulk


def test_fifo_within_one_priority(tmp_db):
    first = tmp_db.enqueue_job("convert", video_id=1)
    second = tmp_db.enqueue_job("convert", video_id=2)

    assert tmp_db.claim_job()["id"] == first
    assert tmp_db.claim_job()["id"] == second


def test_claim_is_exclusive(tmp_db):
    """The actual concurrency guarantee: one queued row yields exactly one claim."""
    tmp_db.enqueue_job("convert", video_id=1)

    assert tmp_db.claim_job() is not None
    assert tmp_db.claim_job() is None


def test_duplicate_enqueue_is_a_noop_while_queued(tmp_db):
    first = tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is None
    assert tmp_db.claim_job()["id"] == first
    assert tmp_db.claim_job() is None


def test_duplicate_enqueue_is_a_noop_while_running(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    tmp_db.claim_job()
    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is None


def test_enqueue_allowed_again_after_done(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "done")

    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is not None


def test_dedup_applies_to_version_less_kinds(tmp_db):
    """version_id defaults to 0, not NULL — NULLs are distinct in a unique index,
    which would silently disable dedup for normalize and hls."""
    assert tmp_db.enqueue_job("normalize", video_id=1) is not None
    assert tmp_db.enqueue_job("normalize", video_id=1) is None


def test_different_kinds_for_one_video_coexist(tmp_db):
    assert tmp_db.enqueue_job("convert", video_id=1) is not None
    assert tmp_db.enqueue_job("hls", video_id=1) is not None


def test_finish_job_records_status_error_and_result(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "done", result={"output_path": "/tmp/out.mp4"})

    stored = tmp_db.get_job(job["id"])
    assert stored["status"] == "done"
    assert stored["result"] == {"output_path": "/tmp/out.mp4"}
    assert stored["finished_at"] is not None


def test_finish_job_records_failure(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "failed", error_msg="ffmpeg exploded")

    stored = tmp_db.get_job(job["id"])
    assert stored["status"] == "failed"
    assert stored["error_msg"] == "ffmpeg exploded"


def test_requeue_job_makes_it_claimable_again(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.requeue_job(job["id"])

    again = tmp_db.claim_job()
    assert again["id"] == job["id"]
    assert again["attempts"] == 2


def test_reset_orphan_jobs_requeues_running_rows_and_returns_them(tmp_db):
    tmp_db.enqueue_job("convert", video_id=42, version_id=7)
    claimed = tmp_db.claim_job()

    orphans = tmp_db.reset_orphan_jobs()

    assert [o["id"] for o in orphans] == [claimed["id"]]
    assert orphans[0]["video_id"] == 42
    assert tmp_db.get_job(claimed["id"])["status"] == "queued"


def test_reset_orphan_jobs_leaves_queued_and_done_alone(tmp_db):
    queued = tmp_db.enqueue_job("convert", video_id=1)
    tmp_db.enqueue_job("hls", video_id=2)
    done = tmp_db.claim_job()
    tmp_db.finish_job(done["id"], "done")

    assert tmp_db.reset_orphan_jobs() == []
    assert tmp_db.get_job(queued)["status"] == "queued"
    assert tmp_db.get_job(done["id"])["status"] == "done"


def test_exhausted_job_is_never_claimed(tmp_db):
    """A job that kills the runner every time must not be reclaimed forever."""
    tmp_db.enqueue_job("convert", video_id=1)
    for _ in range(tmp_db.MAX_JOB_ATTEMPTS):
        job = tmp_db.claim_job()
        assert job is not None
        tmp_db.requeue_job(job["id"])

    assert tmp_db.claim_job() is None


def test_sweep_marks_exhausted_jobs_failed(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    for _ in range(tmp_db.MAX_JOB_ATTEMPTS):
        job = tmp_db.claim_job()
        tmp_db.requeue_job(job["id"])

    assert tmp_db.sweep_exhausted_jobs() == 1
    assert tmp_db.get_job(job["id"])["status"] == "failed"
    assert "attempts" in tmp_db.get_job(job["id"])["error_msg"]


def test_queued_job_count_excludes_running_and_finished(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    tmp_db.enqueue_job("convert", video_id=2)
    tmp_db.enqueue_job("convert", video_id=3)
    tmp_db.claim_job()

    assert tmp_db.queued_job_count() == 2


def test_init_db_is_idempotent_with_the_jobs_table(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    tmp_db.init_db()
    assert tmp_db.queued_job_count() == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_jobs.py -v`
Expected: FAIL — `AttributeError: module 'db' has no attribute 'enqueue_job'`

- [ ] **Step 3: Add the `jobs` DDL to `init_db`**

In `db.py`, inside `init_db()`, append to the `conn.executescript(...)` block (or add a second `executescript` right after it — either is fine, it is the same idempotent-guard convention):

```sql
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL,
    video_id INTEGER NOT NULL,
    version_id INTEGER NOT NULL DEFAULT 0,
    payload TEXT,
    result TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    error_msg TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT
);

-- Enqueueing work that is already pending is a no-op. version_id is 0 (never
-- NULL) for kinds without a version: SQLite treats NULLs as distinct in a
-- unique index, which would silently disable dedup for exactly those kinds.
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_pending
    ON jobs (kind, video_id, version_id)
    WHERE status IN ('queued', 'running');

CREATE INDEX IF NOT EXISTS idx_jobs_claim ON jobs (status, priority, id);
```

- [ ] **Step 4: Add the write-lock connection helper**

In `db.py`, right after `_conn` (which ends at `db.py:27`):

```python
@contextmanager
def _write_conn():
    """Like _conn(), but takes the write lock before the first read.

    Claiming a job reads the queue and writes the claim in one transaction. A
    deferred transaction starts on a read snapshot and can fail to upgrade with
    SQLITE_BUSY_SNAPSHOT — an error busy_timeout does not retry, unlike plain
    SQLITE_BUSY. BEGIN IMMEDIATE takes the write lock up front, so concurrent
    claimers queue on busy_timeout instead of erroring out.
    """
    conn = sqlite3.connect(
        os.getenv("DB_PATH", "data/watch_later.sqlite"), timeout=30, isolation_level=None
    )
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()
```

- [ ] **Step 5: Add the queue functions**

Append to `db.py`:

```python
JOB_KINDS = ("convert", "hls", "normalize")
PRIORITY_INTERACTIVE = 0
PRIORITY_BULK = 100


def _job_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


MAX_JOB_ATTEMPTS = _job_int_env("MAX_JOB_ATTEMPTS", 3)


def _job_row(row: sqlite3.Row | None) -> dict | None:
    """Rows out of the jobs table with payload/result decoded from JSON."""
    if row is None:
        return None
    job = dict(row)
    for field in ("payload", "result"):
        raw = job.get(field)
        try:
            job[field] = json.loads(raw) if raw else None
        except (TypeError, ValueError):
            job[field] = None
    return job


def enqueue_job(
    kind: str,
    video_id: int,
    version_id: int = 0,
    priority: int = PRIORITY_INTERACTIVE,
    payload: dict | None = None,
) -> int | None:
    """Queue ffmpeg work for converter.py. Returns None if it is already pending."""
    if kind not in JOB_KINDS:
        raise ValueError(f"Unknown job kind: {kind}")
    with _conn() as conn:
        cursor = conn.execute(
            """
            INSERT INTO jobs (kind, video_id, version_id, payload, priority, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            (
                kind,
                video_id,
                version_id,
                json.dumps(payload) if payload else None,
                priority,
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        return cursor.lastrowid if cursor.rowcount else None


def claim_job() -> dict | None:
    """Atomically take the next eligible job. Skips jobs at MAX_JOB_ATTEMPTS."""
    with _write_conn() as conn:
        row = conn.execute(
            """
            UPDATE jobs
            SET status = 'running', started_at = ?, attempts = attempts + 1
            WHERE id = (
                SELECT id FROM jobs
                WHERE status = 'queued' AND attempts < ?
                ORDER BY priority, id LIMIT 1
            )
            RETURNING *
            """,
            (datetime.now(timezone.utc).isoformat(), MAX_JOB_ATTEMPTS),
        ).fetchone()
        return _job_row(row)


def finish_job(
    job_id: int, status: str, error_msg: str | None = None, result: dict | None = None
) -> None:
    with _conn() as conn:
        conn.execute(
            """
            UPDATE jobs
            SET status = ?, error_msg = ?, result = ?, finished_at = ?
            WHERE id = ?
            """,
            (
                status,
                error_msg,
                json.dumps(result) if result else None,
                datetime.now(timezone.utc).isoformat(),
                job_id,
            ),
        )


def requeue_job(job_id: int) -> None:
    """Hand a job back to the queue. attempts is not decremented, so a job that
    keeps killing the runner eventually stops being claimed."""
    with _conn() as conn:
        conn.execute(
            "UPDATE jobs SET status = 'queued', started_at = NULL WHERE id = ?", (job_id,)
        )


def reset_orphan_jobs() -> list[dict]:
    """Requeue every 'running' job and return them.

    Only converter.py runs jobs, so at its startup nothing can legitimately be
    running: anything still marked so is debris from a crash. Returned rows let
    the caller delete each job's leftover temp file before it runs again.
    """
    with _write_conn() as conn:
        rows = conn.execute("SELECT * FROM jobs WHERE status = 'running'").fetchall()
        conn.execute(
            "UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'running'"
        )
        return [_job_row(row) for row in rows]


def sweep_exhausted_jobs() -> int:
    """Fail jobs that hit the attempt ceiling so they leave the queue depth gauge."""
    with _conn() as conn:
        cursor = conn.execute(
            """
            UPDATE jobs
            SET status = 'failed', error_msg = ?, finished_at = ?
            WHERE status = 'queued' AND attempts >= ?
            """,
            (
                f"gave up after {MAX_JOB_ATTEMPTS} attempts",
                datetime.now(timezone.utc).isoformat(),
                MAX_JOB_ATTEMPTS,
            ),
        )
        return cursor.rowcount


def queued_job_count() -> int:
    with _conn() as conn:
        return conn.execute("SELECT COUNT(*) FROM jobs WHERE status = 'queued'").fetchone()[0]


def get_job(job_id: int) -> dict | None:
    with _conn() as conn:
        return _job_row(conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone())
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `python -m pytest tests/test_jobs.py -v`
Expected: PASS, all tests.

- [ ] **Step 7: Run the full suite to confirm nothing regressed**

Run: `python -m pytest tests/ -q`
Expected: PASS. `init_db` gained a table; nothing else changed yet.

- [ ] **Step 8: Commit**

```bash
git add db.py tests/test_jobs.py
git commit -m "feat(db): add durable jobs queue for ffmpeg work

Priority-ordered, FIFO within a priority, deduped on
(kind, video_id, version_id) while pending. Claim runs under
BEGIN IMMEDIATE so concurrent claimers serialize on busy_timeout
instead of failing with SQLITE_BUSY_SNAPSHOT.

No callers yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `converter.py` runner process

The process that actually enforces the cap. Still no callers enqueueing — this task ends with a runner that correctly drains a queue you fill by hand in a test.

**Files:**
- Create: `converter.py`
- Modify: `library.py` (extract `temp_target_for`, use it in `convert_library_video`)
- Test: `tests/test_converter.py` (create)

**Interfaces:**
- Consumes: everything Task 1 produced; `library.convert_library_video(video_id)`, `library.conversion_target(source, existing)`, `hls.prepare(video_id, source_path)`, `hls.invalidate(video_id)`, `downloader._normalize_media_for_ios_sync(path)`, `db.get_video_version(video_id, version_id=None)`.
- Produces:
  - `library.temp_target_for(video_id: int) -> Path | None` — the hidden `.name.mp4` temp path a convert job would write, or `None` if the row/version is gone.
  - `converter.JOB_HANDLERS: dict[str, Callable[[dict], dict | None]]` — kind → handler. A handler takes a claimed job dict and returns an optional `result` dict.
  - `converter.run_job(job: dict) -> None` — dispatch one job, record `done`/`failed`.
  - `converter.cleanup_orphan(job: dict) -> None` — delete a crashed job's partial output.
  - `converter.worker_loop(stop: threading.Event, poll_interval: float = 1.0) -> None`
  - `converter.main() -> None` — arg parsing, orphan reset, thread pool, signal handling.
  - `converter.FFMPEG_JOB_LIMIT: int`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_converter.py`:

```python
# tests/test_converter.py
import threading
import time

import pytest


@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


def test_convert_job_success_marks_job_done(tmp_db, monkeypatch):
    import converter

    called = []
    monkeypatch.setitem(
        converter.JOB_HANDLERS, "convert", lambda job: called.append(job["video_id"])
    )
    tmp_db.enqueue_job("convert", video_id=42)

    converter.run_job(tmp_db.claim_job())

    assert called == [42]
    assert tmp_db.get_job(1)["status"] == "done"


def test_handler_raising_marks_job_failed_with_the_message(tmp_db, monkeypatch):
    import converter

    def boom(job):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setitem(converter.JOB_HANDLERS, "convert", boom)
    tmp_db.enqueue_job("convert", video_id=42)

    converter.run_job(tmp_db.claim_job())

    job = tmp_db.get_job(1)
    assert job["status"] == "failed"
    assert "ffmpeg exploded" in job["error_msg"]


def test_handler_result_is_stored_on_the_job(tmp_db, monkeypatch):
    import converter

    monkeypatch.setitem(
        converter.JOB_HANDLERS, "normalize", lambda job: {"output_path": "/tmp/out.mp4"}
    )
    tmp_db.enqueue_job("normalize", video_id=7)

    converter.run_job(tmp_db.claim_job())

    assert tmp_db.get_job(1)["result"] == {"output_path": "/tmp/out.mp4"}


def test_unknown_kind_fails_the_job_instead_of_crashing_the_runner(tmp_db):
    import converter

    tmp_db.enqueue_job("convert", video_id=1)
    job = tmp_db.claim_job()
    job["kind"] = "bogus"

    converter.run_job(job)

    assert tmp_db.get_job(1)["status"] == "failed"


def test_worker_loop_drains_the_queue_then_idles(tmp_db, monkeypatch):
    import converter

    monkeypatch.setitem(converter.JOB_HANDLERS, "convert", lambda job: None)
    for video_id in range(1, 4):
        tmp_db.enqueue_job("convert", video_id=video_id)

    stop = threading.Event()
    thread = threading.Thread(
        target=converter.worker_loop, args=(stop,), kwargs={"poll_interval": 0.01}
    )
    thread.start()
    deadline = time.monotonic() + 5
    while tmp_db.queued_job_count() and time.monotonic() < deadline:
        time.sleep(0.01)
    stop.set()
    thread.join(timeout=5)

    assert not thread.is_alive()
    assert tmp_db.queued_job_count() == 0


def test_cap_holds_under_a_burst(tmp_db, monkeypatch):
    """The regression test for the incident: N queued jobs, FFMPEG_JOB_LIMIT
    workers, and the handler never sees more than the limit running at once."""
    import converter

    limit = 1
    concurrent = 0
    peak = 0
    guard = threading.Lock()

    def handler(job):
        nonlocal concurrent, peak
        with guard:
            concurrent += 1
            peak = max(peak, concurrent)
        time.sleep(0.02)
        with guard:
            concurrent -= 1

    monkeypatch.setitem(converter.JOB_HANDLERS, "convert", handler)
    for video_id in range(1, 21):
        tmp_db.enqueue_job("convert", video_id=video_id)

    stop = threading.Event()
    threads = [
        threading.Thread(
            target=converter.worker_loop, args=(stop,), kwargs={"poll_interval": 0.01}
        )
        for _ in range(limit)
    ]
    for thread in threads:
        thread.start()
    deadline = time.monotonic() + 15
    while tmp_db.queued_job_count() and time.monotonic() < deadline:
        time.sleep(0.01)
    stop.set()
    for thread in threads:
        thread.join(timeout=5)

    assert tmp_db.queued_job_count() == 0
    assert peak <= limit


def test_cleanup_orphan_deletes_a_convert_temp_file(tmp_db, monkeypatch, tmp_path):
    import converter
    import library

    temp = tmp_path / ".movie.mp4"
    temp.write_bytes(b"partial")
    monkeypatch.setattr(library, "temp_target_for", lambda video_id: temp)

    converter.cleanup_orphan({"kind": "convert", "video_id": 42, "payload": None})

    assert not temp.exists()


def test_cleanup_orphan_invalidates_partial_hls_output(tmp_db, monkeypatch):
    import converter
    import hls

    invalidated = []
    monkeypatch.setattr(hls, "invalidate", invalidated.append)

    converter.cleanup_orphan({"kind": "hls", "video_id": 42, "payload": None})

    assert invalidated == [42]
```

Add to `tests/test_library.py`:

```python
def test_temp_target_for_is_the_hidden_sibling_of_the_conversion_target(monkeypatch, tmp_path):
    import db
    source = tmp_path / "movie.mkv"
    source.write_bytes(b"")
    monkeypatch.setattr(db, "get_video_version", lambda video_id, version_id=None: {
        "id": 1, "source_path": str(source), "converted_path": None,
    })

    assert library.temp_target_for(42) == tmp_path / ".movie.mp4"


def test_temp_target_for_returns_none_when_the_version_is_gone(monkeypatch):
    import db
    monkeypatch.setattr(db, "get_video_version", lambda video_id, version_id=None: None)

    assert library.temp_target_for(42) is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_converter.py tests/test_library.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'converter'` and `AttributeError: module 'library' has no attribute 'temp_target_for'`

- [ ] **Step 3: Extract `temp_target_for` in `library.py`**

Add near `conversion_target`:

```python
def temp_target_for(video_id: int) -> Path | None:
    """The hidden temp file a conversion of this row writes before os.replace.

    Shared by convert_library_video and converter.py's orphan cleanup so the
    path has exactly one definition.
    """
    version = db.get_video_version(video_id)
    if not version:
        return None
    target = conversion_target(Path(version["source_path"]), version.get("converted_path"))
    return target.with_name("." + target.name)
```

Then in `convert_library_video`, make `tmp` come from the new helper so there is exactly one derivation of the temp path. Replace these three lines:

```python
        target = conversion_target(source, version.get("converted_path"))
        # Hidden temp file in the same directory: invisible to Plex and our scans,
        # and os.replace stays atomic because it is on the same volume.
        tmp = target.with_name("." + target.name)
```

with:

```python
        target = conversion_target(source, version.get("converted_path"))
        # Hidden temp file in the same directory: invisible to Plex and our scans,
        # and os.replace stays atomic because it is on the same volume.
        # Shared with converter.py's orphan cleanup via temp_target_for().
        tmp = target.with_name("." + target.name)
```

The comment is the only change to this function — `tmp` keeps its existing
derivation, and `temp_target_for` reproduces it from the same
`conversion_target` call. The two `test_temp_target_for_*` tests are what keep
them in step.

- [ ] **Step 4: Write `converter.py`**

```python
#!/usr/bin/env python3
"""The only process in PatataTube that spawns ffmpeg.

Web workers enqueue jobs; this drains them FFMPEG_JOB_LIMIT at a time. Before
this existed, every /prepare request spawned its own ffmpeg through a FastAPI
BackgroundTask — 226 of them at once took the machine down on 2026-07-31.
See docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md.
"""
import argparse
import os
import signal
import threading
import time
import traceback
from pathlib import Path

import db
import hls
import library


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


FFMPEG_JOB_LIMIT = _positive_int_env("FFMPEG_JOB_LIMIT", 1)


def _handle_convert(job: dict) -> None:
    library.convert_library_video(job["video_id"])


def _handle_hls(job: dict) -> None:
    payload = job.get("payload") or {}
    hls.prepare(job["video_id"], payload["source_path"])


def _handle_normalize(job: dict) -> dict:
    # Imported lazily: downloader pulls in pybalt, which the other kinds do not
    # need, and a normalize job is rare compared to convert.
    from downloader import _normalize_media_for_ios_sync

    payload = job.get("payload") or {}
    output = _normalize_media_for_ios_sync(Path(payload["input_path"]))
    return {"output_path": str(output)}


JOB_HANDLERS = {
    "convert": _handle_convert,
    "hls": _handle_hls,
    "normalize": _handle_normalize,
}


def run_job(job: dict) -> None:
    """Dispatch one claimed job and record its outcome. Never raises."""
    started = time.monotonic()
    print(
        f"[job] +1 kind={job['kind']} id={job['video_id']} "
        f"priority={job['priority']} queued={db.queued_job_count()}",
        flush=True,
    )
    try:
        handler = JOB_HANDLERS.get(job["kind"])
        if handler is None:
            raise ValueError(f"Unknown job kind: {job['kind']}")
        result = handler(job)
        db.finish_job(job["id"], "done", result=result)
        status = "done"
    except Exception as exc:  # noqa: BLE001 - a bad job must not kill the runner
        traceback.print_exc()
        db.finish_job(job["id"], "failed", error_msg=str(exc))
        status = "failed"
    print(
        f"[job] -1 kind={job['kind']} id={job['video_id']} "
        f"status={status} secs={time.monotonic() - started:.0f}",
        flush=True,
    )


def cleanup_orphan(job: dict) -> None:
    """Delete the partial output a crashed job left behind.

    Called at startup for every job still marked 'running'. Best-effort: a
    failure here must not stop the runner from draining the queue.
    """
    try:
        if job["kind"] == "convert":
            temp = library.temp_target_for(job["video_id"])
            if temp is not None:
                Path(temp).unlink(missing_ok=True)
        elif job["kind"] == "hls":
            hls.invalidate(job["video_id"])
        # normalize writes into the system temp dir, which the OS reaps.
    except Exception:  # noqa: BLE001
        traceback.print_exc()


def worker_loop(stop: threading.Event, poll_interval: float = 1.0) -> None:
    """Claim and run jobs until stopped. One thread per concurrent ffmpeg."""
    while not stop.is_set():
        job = db.claim_job()
        if job is None:
            stop.wait(poll_interval)
            continue
        run_job(job)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch-pid", type=int)
    parser.add_argument("--poll-interval", type=float, default=1.0)
    args = parser.parse_args()

    db.init_db()

    # Only this process runs jobs, so nothing can legitimately be 'running' at
    # our startup: anything still marked so is debris from a crash.
    for orphan in db.reset_orphan_jobs():
        print(f"[job] requeued orphan kind={orphan['kind']} id={orphan['video_id']}", flush=True)
        cleanup_orphan(orphan)
    swept = db.sweep_exhausted_jobs()
    if swept:
        print(f"[job] failed {swept} job(s) past {db.MAX_JOB_ATTEMPTS} attempts", flush=True)

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    threads = [
        threading.Thread(target=worker_loop, args=(stop, args.poll_interval), daemon=True)
        for _ in range(FFMPEG_JOB_LIMIT)
    ]
    for thread in threads:
        thread.start()
    print(f"[job] converter up, limit={FFMPEG_JOB_LIMIT}", flush=True)

    # Exit when the parent dies, same contract as caddy_access.py --watch-pid.
    while not stop.is_set():
        if args.watch_pid is not None and not _process_exists(args.watch_pid):
            stop.set()
            break
        stop.wait(1.0)

    for thread in threads:
        thread.join(timeout=10)
    # Jobs still 'running' here were killed mid-flight; the next startup's
    # reset_orphan_jobs requeues them and cleans their temps.
    print("[job] converter down", flush=True)


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_converter.py tests/test_library.py -v`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `python -m pytest tests/ -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add converter.py library.py tests/test_converter.py tests/test_library.py
git commit -m "feat(converter): add the single ffmpeg runner process

Claims jobs FFMPEG_JOB_LIMIT at a time (default 1), requeues crash
orphans at startup and deletes their partial output, and exits with
its parent via --watch-pid.

Still no enqueueing callers; the web tier changes next.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Route `/prepare`, audio reconversion, and HLS packaging through the queue

The change that actually stops the web tier from spawning ffmpeg.

**Files:**
- Modify: `router.py:599-633` (`hls_asset`), `router.py:776-810` (`api_choose_audio`), `router.py:893-968` (`api_prepare_video`), `router.py:145-146` (`PrepareRequest`)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.enqueue_job`, `db.PRIORITY_INTERACTIVE`, `db.PRIORITY_BULK`, `db.queued_job_count`.
- Produces: `PrepareRequest.priority: str | None` — accepts `"bulk"`; anything else (including omitted) is interactive.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py` (using the existing `client` fixture):

```python
def test_prepare_enqueues_instead_of_spawning(client, monkeypatch):
    import db
    import library

    spawned = []
    monkeypatch.setattr(library, "convert_library_video", lambda vid: spawned.append(vid))
    video_id = _library_row_needing_conversion(client)

    response = client.post(
        f"/api/videos/{video_id}/prepare", headers=_auth(), json={}
    )

    assert response.status_code == 202
    assert response.json()["status"] == "converting"
    assert spawned == []
    assert db.queued_job_count() == 1


def test_prepare_passthrough_creates_no_job(client, monkeypatch):
    import db
    video_id = _library_row_that_passes_through(client)

    response = client.post(f"/api/videos/{video_id}/prepare", headers=_auth(), json={})

    assert response.json()["status"] == "done"
    assert db.queued_job_count() == 0


def test_bulk_prepare_is_queued_behind_interactive(client):
    import db

    bulk_id = _library_row_needing_conversion(client)
    interactive_id = _library_row_needing_conversion(client)

    client.post(
        f"/api/videos/{bulk_id}/prepare", headers=_auth(), json={"priority": "bulk"}
    )
    client.post(f"/api/videos/{interactive_id}/prepare", headers=_auth(), json={})

    assert db.claim_job()["video_id"] == interactive_id
    assert db.claim_job()["video_id"] == bulk_id


def test_prepare_storm_spawns_no_ffmpeg(client, monkeypatch):
    """The incident, as a test: many prepares, zero ffmpeg from the web process."""
    import db
    import library

    spawned = []
    monkeypatch.setattr(library, "convert_library_video", lambda vid: spawned.append(vid))
    video_ids = [_library_row_needing_conversion(client) for _ in range(25)]

    for video_id in video_ids:
        client.post(
            f"/api/videos/{video_id}/prepare", headers=_auth(), json={"priority": "bulk"}
        )

    assert spawned == []
    assert db.queued_job_count() == 25


def test_repeated_prepare_for_one_video_queues_one_job(client):
    import db
    video_id = _library_row_needing_conversion(client)

    client.post(f"/api/videos/{video_id}/prepare", headers=_auth(), json={})
    client.post(f"/api/videos/{video_id}/prepare", headers=_auth(), json={})

    assert db.queued_job_count() == 1


def test_audio_change_enqueues_reconversion_instead_of_spawning(client, monkeypatch):
    import db
    import library

    spawned = []
    monkeypatch.setattr(library, "convert_library_video", lambda *args: spawned.append(args))
    video_id, version_id = _ready_library_row_with_alternate_audio(client)

    response = client.post(
        f"/api/videos/{video_id}/audio", headers=_auth(), json={"lang": "spa"}
    )

    assert response.status_code == 200
    assert spawned == []
    job = db.claim_job()
    assert job["kind"] == "convert"
    assert job["video_id"] == video_id
    assert job["version_id"] == version_id


def test_cold_master_playlist_enqueues_an_hls_job(client, monkeypatch):
    import db
    import hls

    packaged = []
    monkeypatch.setattr(hls, "prepare", lambda vid, src: packaged.append(vid))
    video_id = _ready_library_row(client)

    response = client.get(f"/videos/{video_id}/hls/master.m3u8", headers=_auth())

    assert response.status_code == 409
    assert packaged == []
    job = db.claim_job()
    assert job["kind"] == "hls"
    assert job["payload"]["source_path"]
```

> The `_library_row_needing_conversion`, `_library_row_that_passes_through`, `_ready_library_row`, `_ready_library_row_with_alternate_audio`, and `_auth` helpers: reuse whatever the existing library/prepare tests in `tests/test_api.py` already use to build a library row and auth header. If no such helper exists, write them next to the existing library tests, following how those tests seed rows via `db.upsert_library_video` and monkeypatch `library.probe_source` to return a probe that does / does not pass `plan_conversion`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "prepare or hls_job or master_playlist" -v`
Expected: FAIL — jobs are not enqueued, `queued_job_count()` is 0.

- [ ] **Step 3: Add `priority` to `PrepareRequest`**

Replace `router.py:145-146`:

```python
class PrepareRequest(BaseModel):
    audio_lang: str | None = None
    # "bulk" is the iOS Download-all path. Anything else, including omitted,
    # is interactive and jumps ahead of a bulk drain.
    priority: str | None = None
```

- [ ] **Step 4: Enqueue in `api_prepare_video`**

Replace `router.py:965-968`:

```python
    db.set_library_state(video_id, "converting", version_id=version["id"])

    background_tasks.add_task(library.convert_library_video, video_id)
    return JSONResponse({"status": "converting"}, status_code=202)
```

with:

```python
    db.set_library_state(video_id, "converting", version_id=version["id"])

    # converter.py is the only process that spawns ffmpeg. Enqueueing an
    # already-pending job is a no-op, which is why the comment above about
    # racing concurrent requests no longer needs to be airtight.
    priority = db.PRIORITY_BULK if body and body.priority == "bulk" else db.PRIORITY_INTERACTIVE
    db.enqueue_job("convert", video_id, version_id=version["id"], priority=priority)
    return JSONResponse({"status": "converting"}, status_code=202)
```

Also drop `background_tasks: BackgroundTasks` from the signature at `router.py:897` — it is now unused here.

- [ ] **Step 5: Enqueue audio-change reconversions**

In `api_choose_audio`, replace the final conversion handoff:

```python
    if version["status"] == "done" and (converted is None or body.lang not in converted):
        db.set_library_state(video_id, "converting", version_id=version["id"])
        background_tasks.add_task(library.convert_library_video, video_id)
```

with:

```python
    if version["status"] == "done" and (converted is None or body.lang not in converted):
        db.set_library_state(video_id, "converting", version_id=version["id"])
        db.enqueue_job(
            "convert", video_id, version_id=version["id"],
            priority=db.PRIORITY_INTERACTIVE,
        )
```

Also drop `background_tasks: BackgroundTasks` from `api_choose_audio`'s signature. The module import remains necessary for upload routes, but this endpoint must not schedule a direct ffmpeg conversion.

- [ ] **Step 6: Enqueue in `hls_asset`**

Replace `router.py:620-631`:

```python
    # Nothing on disk yet. Only the master request triggers packaging; segment
    # and subtitle requests before readiness are simply 404. Packaging runs off
    # the event loop and the client polls the master URL until it is 200.
    #
    # Return a real 409 Response (not raise): FastAPI only runs the injected
    # BackgroundTasks when the endpoint *returns* a response — a raised
    # HTTPException drops them, so the prep task would never fire.
    if asset_path == "master.m3u8":
        if video.get("hls_status") != "converting":
            db.set_hls_status(video_id, "converting")
            background_tasks.add_task(hls.prepare, video_id, str(source))
        return JSONResponse({"detail": "HLS preparing"}, status_code=409)
```

with:

```python
    # Nothing on disk yet. Only the master request triggers packaging; segment
    # and subtitle requests before readiness are simply 404. Packaging is queued
    # for converter.py and the client polls the master URL until it is 200.
    if asset_path == "master.m3u8":
        if video.get("hls_status") != "converting":
            db.set_hls_status(video_id, "converting")
        db.enqueue_job(
            "hls", video_id, priority=db.PRIORITY_INTERACTIVE,
            payload={"source_path": str(source)},
        )
        return JSONResponse({"detail": "HLS preparing"}, status_code=409)
```

Note the enqueue moved outside the status guard: dedup now lives in the unique index, and this way a row wedged at `converting` by an old crash still gets a job. Drop `background_tasks: BackgroundTasks` from the signature at `router.py:601`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS. If other tests asserted that `/prepare` invoked `library.convert_library_video`, update them to assert a queued job instead — that behavior intentionally moved.

- [ ] **Step 8: Run the full suite**

Run: `python -m pytest tests/ -q`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "fix(api): queue conversions instead of spawning ffmpeg per request

/prepare, audio-change reconversions, and a cold master.m3u8 now enqueue for converter.py rather
than scheduling a BackgroundTask. This is the fix for the 2026-07-31
outage: 226 prepares no longer mean 226 concurrent ffmpeg processes,
and the anyio threadpool stays free to serve requests.

PrepareRequest gains priority='bulk' so Download-all queues behind
interactive taps.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Route download normalization through the queue

The third ffmpeg spawner. Smaller blast radius than Task 3 but part of "one global budget".

**Files:**
- Modify: `downloader.py:94-95`
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `db.enqueue_job`, `db.get_job`.
- Produces: `_normalize_media_for_ios(input_path: Path, video_id: int) -> Path` — signature gains `video_id` so the job row has a target. Callers `_store_ios_compatible_video` (`downloader.py:82`) already have it.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_downloader.py`:

```python
@pytest.mark.asyncio
async def test_normalize_enqueues_and_awaits_the_job(monkeypatch, tmp_path):
    import db
    import downloader

    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    db.init_db()
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")
    output = tmp_path / "out.mp4"

    spawned = []
    monkeypatch.setattr(
        downloader, "_normalize_media_for_ios_sync", lambda p: spawned.append(p)
    )

    async def finish_the_job_out_of_band():
        await asyncio.sleep(0)
        job = db.claim_job()
        db.finish_job(job["id"], "done", result={"output_path": str(output)})

    result, _ = await asyncio.gather(
        downloader._normalize_media_for_ios(source, video_id=42),
        finish_the_job_out_of_band(),
    )

    assert result == output
    assert spawned == [], "the web process must not run ffmpeg itself"


@pytest.mark.asyncio
async def test_normalize_raises_when_the_job_fails(monkeypatch, tmp_path):
    import db
    import downloader

    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    db.init_db()
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")

    async def fail_the_job():
        await asyncio.sleep(0)
        job = db.claim_job()
        db.finish_job(job["id"], "failed", error_msg="bad codec")

    with pytest.raises(RuntimeError, match="bad codec"):
        await asyncio.gather(
            downloader._normalize_media_for_ios(source, video_id=42),
            fail_the_job(),
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_downloader.py -k normalize -v`
Expected: FAIL — `TypeError: _normalize_media_for_ios() got an unexpected keyword argument 'video_id'`

- [ ] **Step 3: Rewrite `_normalize_media_for_ios`**

Replace `downloader.py:94-95`:

```python
async def _normalize_media_for_ios(input_path: Path) -> Path:
    return await asyncio.to_thread(_normalize_media_for_ios_sync, input_path)
```

with:

```python
NORMALIZE_POLL_SECONDS = 1.0


async def _normalize_media_for_ios(input_path: Path, video_id: int) -> Path:
    """Hand the ffmpeg work to converter.py and wait for it.

    Polling rather than to_thread: this runs as a BackgroundTask on the event
    loop, so waiting costs no thread, and converter.py is the only process
    allowed to spawn ffmpeg.
    """
    job_id = db.enqueue_job("normalize", video_id, payload={"input_path": str(input_path)})
    if job_id is None:
        raise RuntimeError(f"A normalize job for video {video_id} is already pending")

    while True:
        job = db.get_job(job_id)
        if job["status"] == "done":
            return Path((job["result"] or {})["output_path"])
        if job["status"] == "failed":
            raise RuntimeError(job["error_msg"] or "normalization failed")
        await asyncio.sleep(NORMALIZE_POLL_SECONDS)
```

- [ ] **Step 4: Update the one caller**

In `_store_ios_compatible_video` (`downloader.py:81-91`), change:

```python
    normalized_path = await _normalize_media_for_ios(downloaded_path)
```

to:

```python
    normalized_path = await _normalize_media_for_ios(downloaded_path, video_id)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_downloader.py -v`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `python -m pytest tests/ -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "fix(downloader): normalize uploads via the job queue

The third and last ffmpeg spawner in the web tier. Waits by polling the
job row, which costs no thread since download_video already runs on the
event loop.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Supervise the converter in `./serve`, document it

Without this the queue fills and nothing drains it. Docs ride along because `CLAUDE.md` enumerates the log labels and would now be wrong.

**Files:**
- Modify: `serve` (after the `caddy_access.py` block ending at `serve:62`)
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `converter.py --watch-pid`.
- Produces: nothing importable. A `convert`-labeled stream in `log/backend.log`.

- [ ] **Step 1: Add the supervised child to `serve`**

Insert after the `caddy_access.py` background block (which ends with `| colorize 35 caddy >&3 &` at `serve:62`) and before the `if [ "$DEV" = "1" ]` block:

```bash
# converter.py is the only process that spawns ffmpeg; web workers only enqueue.
# It starts before the web server so the jobs table exists and the queue is
# draining by the time requests arrive. The until-loop respawns it on crash:
# unlike gunicorn's workers, a bare background child that died would stall the
# whole queue silently. $$ survives the exec below, so --watch-pid works in both
# the DEV and production paths, exactly as the caddy_access.py line above does.
( until "$PYTHON_BIN" -u converter.py --watch-pid "$$"; do sleep 1; done ) 2>&1 \
  | colorize 31 convert >&3 &
```

- [ ] **Step 2: Verify it starts, drains, and respawns**

```bash
DEV=1 ./serve
```

In another shell:

```bash
grep convert log/backend.log        # expect "[job] converter up, limit=1"
pgrep -fl converter.py              # expect exactly one
pkill -f converter.py; sleep 3; pgrep -fl converter.py   # expect it came back
```

Then stop `./serve` (Ctrl-C) and confirm `pgrep -f converter.py` is empty — `--watch-pid` teardown.

Expected: converter starts, survives a kill, and dies with its parent.

- [ ] **Step 3: Update `CLAUDE.md`**

In the Backend Debugging section, change the labeled-stream list from:

> `./serve` mirrors every labeled stream (`dev`/`web`/`caddy`/`access`/`app`) to it

to:

> `./serve` mirrors every labeled stream (`dev`/`web`/`caddy`/`access`/`app`/`convert`) to it

Add to the Architecture section, after the "Request → download → serve flow" list:

```markdown
### ffmpeg runs in exactly one process

`converter.py` is the only process that spawns ffmpeg. Web workers never do —
`/api/videos/{id}/prepare`, a cold `master.m3u8`, and upload normalization all
call `db.enqueue_job` and return immediately. The runner claims jobs
`FFMPEG_JOB_LIMIT` at a time (default 1, env-overridable) from the `jobs` table,
ordered by `priority` then `id`; `priority=100` is the iOS Download-all path and
queues behind interactive taps at `priority=0`.

`./serve` starts it as a supervised child (`until ... do sleep 1; done`) that
exits with its parent via `--watch-pid`. Queue depth is visible in
`log/backend.log`:

    [job] +1 kind=convert id=812 priority=100 queued=225
    [job] -1 kind=convert id=812 status=done secs=412

Only this process may run ffmpeg — that is the invariant that makes the startup
orphan reset correct (nothing else can hold a `running` job) and the cap real.
Adding a fourth ffmpeg call site means adding a job kind, not a BackgroundTask.
This exists because 226 concurrent BackgroundTask conversions took the machine
down on 2026-07-31; see `docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md`.

**Dev caveat:** `--reload` restarts uvicorn but not the converter. Editing
`converter.py` or `library.py` needs a full `./serve` restart.
```

- [ ] **Step 4: Commit**

```bash
git add serve CLAUDE.md
git commit -m "feat(serve): supervise the converter process

Respawns on crash and exits with its parent. Without it the queue fills
and nothing drains it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: iOS bulk-priority signalling

The server is already correct without this — every job would just be priority 0 and the queue plain FIFO. This is what stops a tap-to-play from waiting behind a 226-job drain.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift:48` (protocol), `:144-145` (implementation)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift:244-257`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:293` (`download`), `:347-361` (`downloadAll`)

**Interfaces:**
- Consumes: the server's `PrepareRequest.priority` from Task 3.
- Produces:
  - `APIClient.prepare(id: Int, bulk: Bool) -> String` (protocol + impl)
  - `VideoStore.ensureReady(id: Int, bulk: Bool = false, pollIntervalSeconds: Double = 2.0) -> Video`
  - `VideoGridView.download(_ video: Video, bulk: Bool = false) -> Bool`

- [ ] **Step 1: Add `bulk` to the API client**

In `APIClient.swift`, change the protocol requirement at line 48:

```swift
    func prepare(id: Int, bulk: Bool) async throws -> String
```

and the implementation at lines 144-145:

```swift
    public func prepare(id: Int, bulk: Bool = false) async throws -> String {
        let body: [String: String] = bulk ? ["priority": "bulk"] : [:]
        let data = try await authedPost("api/videos/\(id)/prepare", body: body)
```

Leave the rest of the method body unchanged.

- [ ] **Step 2: Thread it through `VideoStore.ensureReady`**

In `VideoStore.swift`, change lines 244-245:

```swift
    public func ensureReady(id: Int, bulk: Bool = false, pollIntervalSeconds: Double = 2.0) async throws -> Video {
        let status = try await api.prepare(id: id, bulk: bulk)
```

The rest of the method (the poll loop, lines 246-257) is unchanged. The default means every existing caller keeps interactive priority.

- [ ] **Step 3: Pass `bulk: true` from `downloadAll`**

In `VideoGridView.swift`, change the `download` signature at line 293:

```swift
    private func download(_ video: Video, bulk: Bool = false) async -> Bool {
```

and its `ensureReady` call a few lines below:

```swift
                target = try await preparationTracker.track(videoID: video.id) {
                    try await store.ensureReady(id: video.id, bulk: bulk)
                }
```

Then in `downloadAll` (line 357), replace the misleading comment and pass the flag:

```swift
        // Bulk priority: these queue behind any interactive tap on the server.
        // NOTE: the CacheManager gate bounds the transfers, not these prepare
        // calls — ensureReady runs before the gate is acquired. The server-side
        // job queue is what bounds the conversions.
        await withTaskGroup(of: Void.self) { group in
            for video in targets {
                group.addTask { await download(video, bulk: true) }
            }
        }
```

- [ ] **Step 4: Build the package and the app**

```bash
cd ios/PatataTubeKit && swift build && swift test
cd ../PatataTube && xcodegen generate
```

Expected: build succeeds, existing `swift test` passes. (The pre-existing unrelated `Fatal error: Index out of range` from the parallel swift-testing suites still appears; every test still reports passing — see `CLAUDE.md`.)

- [ ] **Step 5: Commit**

```bash
git add ios/
git commit -m "feat(ios): send bulk priority from Download all

Download-all prepares now queue behind interactive taps on the server,
so tapping play during a bulk drain does not wait hours.

Also corrects the downloadAll comment: the CacheManager gate bounds
transfers, not prepare calls — that was the false assumption behind the
2026-07-31 outage.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Post-implementation: clear the existing wedge

Not code. Do this once, after Task 5 is deployed, or the 226 rows stay stuck forever — they predate the `jobs` table, so the runner's orphan reset cannot see them.

- [ ] **Step 1: Confirm the count first**

```bash
sqlite3 data/watch_later.sqlite \
  "SELECT COUNT(*) FROM videos WHERE status='converting' AND source='library';"
```
Expected: 226.

- [ ] **Step 2: Reset the wedged rows**

> **Warning:** This rewrites 226 rows in the live database. Take a copy of `data/watch_later.sqlite` first. It only moves rows from `converting` back to `unconverted`, so the worst case is that they re-convert.

```bash
cp data/watch_later.sqlite data/watch_later.sqlite.bak
sqlite3 data/watch_later.sqlite \
  "UPDATE videos SET status='unconverted' WHERE status='converting' AND source='library';
   UPDATE video_versions SET status='unconverted' WHERE status='converting';"
```

- [ ] **Step 3: Delete the 193 orphan temp files (6.05 GB)**

Match only the real ffmpeg temps: leading `.` but not macOS's `._` resource forks, and skip `.Trashes`.

```bash
find /Volumes/Media -name ".*.mp4" -type f \
  -not -name "._*" -not -path "*/.Trashes/*" -print   # review this list first
find /Volumes/Media -name ".*.mp4" -type f \
  -not -name "._*" -not -path "*/.Trashes/*" -delete
```

- [ ] **Step 4: Verify the fix end to end**

Hit `Download all` on the `all` filter, then:

```bash
grep '\[job\]' log/backend.log | tail -20   # queued= counts down
pgrep -fc ffmpeg                            # stays at 1
uptime                                      # load stays sane; ssh still answers
```

Expected: exactly one ffmpeg alive, queue depth falling, machine responsive.

---

## Self-Review Notes

**Spec coverage:** every spec section maps to a task — `jobs` table and dedup index → Task 1; `converter.py`, orphan reset, poison-job ceiling, SIGTERM → Task 2; interactive/bulk prepare and HLS data flow → Task 3; normalize data flow → Task 4; `./serve` plus the dev-reload caveat and the `[job]` gauge → Tasks 2 and 5; iOS priority signalling → Task 6; cleanup section → post-implementation. The spec's "row-status contract unchanged" is enforced by keeping `set_library_state` / `set_hls_status` calls exactly where they are and by the existing `tests/test_api.py` suite continuing to pass.

**Type consistency checked:** `enqueue_job` keyword names (`kind`, `video_id`, `version_id`, `priority`, `payload`) are identical in Tasks 1, 3 and 4. `payload` keys are `source_path` for `hls` and `input_path` for `normalize` in both the handler (Task 2) and the caller (Tasks 3, 4). `result` key is `output_path` in both Task 2's handler and Task 4's consumer. `temp_target_for` is defined in Task 2's `library.py` step and used in the same task's `cleanup_orphan`.

**Known deviation from strict TDD:** Task 5 has no automated test — the `./serve` respawn wrapper and `--watch-pid` teardown are shell process supervision, verified by hand exactly as the existing `caddy_access.py` child is. The spec says the same.
