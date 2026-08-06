# ffmpeg Conversion Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a live conversion percentage for server-side ffmpeg work — a determinate ring with the number inside on each video's download button, and a "Converting" section in the iOS Downloads view fed by the server's whole active queue.

**Architecture:** `converter.py` is a separate process from the web workers, so SQLite is the only channel between them: a new `jobs.progress` column carries the number. One shared ffmpeg runner (`ffmpeg_progress.py`) replaces the two `subprocess.run` call sites in `library.py` and `hls.py`, parses `-progress pipe:1` output, and writes throttled updates. A new token-gated `GET /api/jobs` exposes running + the next 20 queued rows with a total; a single iOS `JobsStore` polls it every 2s and both the button and the Downloads view read from it.

**Tech Stack:** Python 3.13 / FastAPI / SQLite (stdlib `sqlite3`) / pytest; Swift 6 / SwiftUI / swift-testing / ViewInspector; SwiftPM package `PatataTubeKit`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-05-ffmpeg-conversion-progress-design.md`. `docs/` is gitignored in this repo — never `git add -f` the spec or this plan.
- Only `converter.py` may spawn ffmpeg. No new ffmpeg call sites; no new BackgroundTask.
- Job kinds in scope: `convert` and `hls`. `normalize` is explicitly out of scope and must be filtered out of `/api/jobs`.
- Schema changes go in `db.init_db()` as idempotent `PRAGMA table_info` guards, never a migrations framework.
- Python tests that touch the API reload `db` then `main` after setting `DB_PATH`/`UPLOAD_TOKEN` — reuse the `client` fixture in `tests/test_api.py`.
- Async Python tests need an explicit `@pytest.mark.asyncio` marker (no global asyncio mode).
- Backend test command: `python -m pytest tests/...`. iOS package: `cd ios/PatataTubeKit && swift test`. App-target tests (`ios/PatataTube/Tests`) have no automated runner — they are compiled and run from Xcode; write them anyway, following the existing files.
- Progress values are `Double`/`float` in 0…1 (a fraction, not 0–100). Only the view layer multiplies by 100.
- `PatataTubeKit` has exactly one external dependency (FlyingFox). Do not add one — no swift-clocks in the package; inject a sleep closure instead.

---

## File Structure

**Create**
- `ffmpeg_progress.py` — the single ffmpeg runner: progress parsing, throttling, stderr capture.
- `tests/test_ffmpeg_progress.py` — its tests.
- `ios/PatataTubeKit/Sources/PatataTubeKit/ConversionJob.swift` — `ConversionJob`, `JobsSnapshot`, `ConversionState`, `JobsAPI`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/JobsStore.swift` — refcounted 2s poller.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/JobsStoreTests.swift`
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientJobsTests.swift`

**Modify**
- `db.py` — `jobs.progress` column guard, `set_job_progress`, `claim_job` reset, `active_jobs`.
- `library.py` — `_run_ffmpeg` deleted, `convert_library_video(on_progress=)`.
- `hls.py` — `_run_ffmpeg` deleted, `prepare(on_progress=)`, `build_hls_package(on_progress=)`.
- `converter.py` — handlers receive and forward a progress callback.
- `router.py` — `GET /api/jobs`.
- `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` — `jobs()` + `VideoAPI`/`JobsAPI` conformance.
- `ios/PatataTube/Sources/DownloadButton.swift` — determinate ring with percent.
- `ios/PatataTube/Sources/VideoGridView.swift` — owns and subscribes the `JobsStore`.
- `ios/PatataTube/Sources/DownloadsView.swift` — "Converting" section.
- `tests/test_db.py`, `tests/test_jobs.py`, `tests/test_api.py`, `tests/test_library.py`, `tests/test_hls.py`, `tests/test_converter.py`
- `ios/PatataTube/Tests/DownloadButtonTests.swift`, `ios/PatataTube/Tests/DownloadsViewTests.swift`

---

### Task 1: The ffmpeg progress runner

**Files:**
- Create: `ffmpeg_progress.py`
- Test: `tests/test_ffmpeg_progress.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `parse_progress_line(line: str) -> float | None` — microseconds elapsed, or None.
  - `probe_duration(probe: dict) -> float` — seconds, 0.0 when unknown.
  - `class ProgressThrottle` with `__init__(self, sink, *, min_delta=0.01, min_interval=2.0, now=time.monotonic)` and `emit(self, fraction: float) -> None`, `flush(self, fraction: float) -> None`.
  - `run_ffmpeg(cmd: list[str], *, duration: float | None = None, on_progress: Callable[[float], None] | None = None) -> None` — raises `RuntimeError` with captured stderr on non-zero exit.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_ffmpeg_progress.py`:

```python
import os
import stat
import pytest

import ffmpeg_progress


def test_parse_progress_line_reads_out_time_us():
    assert ffmpeg_progress.parse_progress_line("out_time_us=1500000") == 1_500_000


def test_parse_progress_line_reads_out_time_ms_as_microseconds():
    # ffmpeg's out_time_ms is microseconds despite the name; older builds emit
    # only that key, so it is the fallback, not a millisecond conversion.
    assert ffmpeg_progress.parse_progress_line("out_time_ms=2000000") == 2_000_000


def test_parse_progress_line_ignores_other_keys_and_garbage():
    assert ffmpeg_progress.parse_progress_line("frame=120") is None
    assert ffmpeg_progress.parse_progress_line("out_time_us=N/A") is None
    assert ffmpeg_progress.parse_progress_line("") is None


def test_probe_duration_reads_format_duration():
    assert ffmpeg_progress.probe_duration({"format": {"duration": "42.5"}}) == 42.5


def test_probe_duration_is_zero_when_missing_or_bad():
    assert ffmpeg_progress.probe_duration({}) == 0.0
    assert ffmpeg_progress.probe_duration({"format": {"duration": "N/A"}}) == 0.0


def test_throttle_emits_first_value_then_only_on_delta():
    seen = []
    clock = [0.0]
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: clock[0])
    throttle.emit(0.0)      # first value always goes out
    throttle.emit(0.005)    # +0.5%, too small, too soon
    throttle.emit(0.02)     # +2%, over the 1% delta
    assert seen == [0.0, 0.02]


def test_throttle_emits_on_interval_even_without_delta():
    seen = []
    clock = [0.0]
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: clock[0])
    throttle.emit(0.0)
    clock[0] = 2.5
    throttle.emit(0.001)
    assert seen == [0.0, 0.001]


def test_throttle_flush_always_emits():
    seen = []
    throttle = ffmpeg_progress.ProgressThrottle(seen.append, now=lambda: 0.0)
    throttle.emit(0.0)
    throttle.flush(1.0)
    assert seen == [0.0, 1.0]


def _fake_binary(tmp_path, script: str):
    path = tmp_path / "fake_ffmpeg"
    path.write_text("#!/bin/sh\n" + script)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(path)


def test_run_ffmpeg_reports_fractions_from_stdout(tmp_path):
    # The fake ignores the -progress flags appended to its argv and just emits
    # what real ffmpeg would emit on stdout.
    binary = _fake_binary(tmp_path, """
echo "frame=1"
echo "out_time_us=5000000"
echo "out_time_us=10000000"
echo "progress=end"
""")
    seen = []
    ffmpeg_progress.run_ffmpeg([binary], duration=20.0, on_progress=seen.append)
    assert seen[0] == pytest.approx(0.25)
    assert seen[-1] == pytest.approx(1.0)


def test_run_ffmpeg_clamps_fraction_to_one(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "out_time_us=30000000"\n')
    seen = []
    ffmpeg_progress.run_ffmpeg([binary], duration=10.0, on_progress=seen.append)
    assert max(seen) == 1.0


def test_run_ffmpeg_appends_progress_flags_only_when_wanted(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "ARGS:$@"\n')
    seen_args = []
    ffmpeg_progress.run_ffmpeg(
        [binary], duration=10.0, on_progress=lambda _f: None,
        _debug_line_sink=seen_args.append,
    )
    assert "-progress pipe:1 -nostats" in seen_args[0]

    seen_args.clear()
    ffmpeg_progress.run_ffmpeg([binary], _debug_line_sink=seen_args.append)
    assert seen_args[0] == "ARGS:"


def test_run_ffmpeg_raises_with_stderr_text_on_failure(tmp_path):
    binary = _fake_binary(tmp_path, 'echo "boom: bad codec" 1>&2\nexit 1\n')
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    assert "boom: bad codec" in str(excinfo.value)


def test_run_ffmpeg_raises_generic_message_when_stderr_is_empty(tmp_path):
    binary = _fake_binary(tmp_path, "exit 1\n")
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    assert "ffmpeg failed" in str(excinfo.value)


def test_run_ffmpeg_survives_a_flood_of_stderr(tmp_path):
    # A full stderr pipe must not deadlock the stdout reader, and the message
    # must stay bounded.
    binary = _fake_binary(tmp_path, 'i=0\nwhile [ $i -lt 5000 ]; do echo "line $i" 1>&2; i=$((i+1)); done\nexit 1\n')
    with pytest.raises(RuntimeError) as excinfo:
        ffmpeg_progress.run_ffmpeg([binary])
    message = str(excinfo.value)
    assert "line 4999" in message
    assert len(message.splitlines()) <= 50
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_ffmpeg_progress.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ffmpeg_progress'`

- [ ] **Step 3: Write the implementation**

Create `ffmpeg_progress.py`:

```python
#!/usr/bin/env python3
"""The one way PatataTube runs ffmpeg, with optional progress reporting.

Both call sites (library.convert_library_video and hls.build_hls_package) used
to shell out with subprocess.run and stderr folded into stdout. Progress needs
stdout to itself (-progress writes there), so stderr moves to its own pipe and
is drained on a thread -- a full stderr pipe would otherwise deadlock the
stdout reader on any verbose failure.
"""
import subprocess
import threading
import time
from collections import deque
from typing import Callable

# Enough lines to explain a failure, few enough to keep an error_msg readable.
STDERR_TAIL_LINES = 50


def parse_progress_line(line: str) -> float | None:
    """Microseconds elapsed from one -progress line, or None if it isn't one.

    `out_time_ms` is also microseconds -- ffmpeg's key name is a long-standing
    misnomer -- so it is a plain fallback, not a unit conversion.
    """
    key, _, raw = line.strip().partition("=")
    if key not in ("out_time_us", "out_time_ms"):
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def probe_duration(probe: dict) -> float:
    """Seconds of media from an ffprobe dict; 0.0 when it can't be determined."""
    try:
        return float((probe or {}).get("format", {}).get("duration") or 0.0)
    except (TypeError, ValueError):
        return 0.0


class ProgressThrottle:
    """Rate-limits progress updates so a long convert writes ~100 rows, not 100k."""

    def __init__(
        self,
        sink: Callable[[float], None],
        *,
        min_delta: float = 0.01,
        min_interval: float = 2.0,
        now: Callable[[], float] = time.monotonic,
    ) -> None:
        self._sink = sink
        self._min_delta = min_delta
        self._min_interval = min_interval
        self._now = now
        self._last_value: float | None = None
        self._last_time = 0.0

    def emit(self, fraction: float) -> None:
        now = self._now()
        if self._last_value is not None:
            advanced = abs(fraction - self._last_value) >= self._min_delta
            waited = (now - self._last_time) >= self._min_interval
            if not advanced and not waited:
                return
        self.flush(fraction)

    def flush(self, fraction: float) -> None:
        self._last_value = fraction
        self._last_time = self._now()
        self._sink(fraction)


def run_ffmpeg(
    cmd: list[str],
    *,
    duration: float | None = None,
    on_progress: Callable[[float], None] | None = None,
    _debug_line_sink: Callable[[str], None] | None = None,
) -> None:
    """Run ffmpeg to completion. Raises RuntimeError with stderr on failure.

    With no duration or no callback this behaves exactly like the old
    subprocess.run path: no extra flags, nothing parsed. That covers passthrough
    conversions and any caller that cannot determine a duration.

    `_debug_line_sink` receives every stdout line and exists only for tests.
    """
    wants_progress = bool(on_progress) and bool(duration) and duration > 0
    full_cmd = list(cmd)
    if wants_progress:
        full_cmd += ["-progress", "pipe:1", "-nostats"]

    throttle = ProgressThrottle(on_progress) if wants_progress else None
    stderr_tail: deque[str] = deque(maxlen=STDERR_TAIL_LINES)

    proc = subprocess.Popen(
        full_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def drain_stderr() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            stderr_tail.append(line.rstrip("\n"))

    stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
    stderr_thread.start()

    last_fraction = 0.0
    assert proc.stdout is not None
    for line in proc.stdout:
        if _debug_line_sink is not None:
            _debug_line_sink(line.rstrip("\n"))
        if throttle is None:
            continue
        if line.strip() == "progress=end":
            throttle.flush(1.0)
            last_fraction = 1.0
            continue
        micros = parse_progress_line(line)
        if micros is None:
            continue
        last_fraction = min(max(micros / (duration * 1_000_000), 0.0), 1.0)
        throttle.emit(last_fraction)

    returncode = proc.wait()
    stderr_thread.join(timeout=5)

    if returncode != 0:
        raise RuntimeError("\n".join(stderr_tail).strip() or "ffmpeg failed")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_ffmpeg_progress.py -v`
Expected: PASS (13 tests)

- [ ] **Step 5: Commit**

```bash
git add ffmpeg_progress.py tests/test_ffmpeg_progress.py
git commit -m "feat: add ffmpeg runner that reports progress"
```

---

### Task 2: `jobs.progress` column and accessors

**Files:**
- Modify: `db.py` (the `PRAGMA table_info` guard block around line 113-168; `claim_job` around line 1197; new functions after `finish_job`)
- Test: `tests/test_jobs.py`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `db.set_job_progress(job_id: int, fraction: float) -> None`
  - `db.active_jobs(queued_limit: int = 20) -> dict` returning
    `{"running": [row, ...], "queued": [row, ...], "queued_total": int}` where each
    row is `{"id", "kind", "video_id", "version_id", "priority", "progress", "title", "show_title"}`
    and `progress` is `float | None`.
  - `db.claim_job` additionally resets `progress` to 0.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_jobs.py` (it already has a fixture that points `DB_PATH` at a tmp db and reloads `db` — follow whatever that file names it; the tests below assume the same `db` module import the existing tests use):

```python
def test_set_job_progress_stores_the_fraction(job_db):
    job_id = db.enqueue_job("convert", video_id=1, version_id=2)
    db.claim_job()
    db.set_job_progress(job_id, 0.42)
    assert db.get_job(job_id)["progress"] == 0.42


def test_claim_job_resets_progress_to_zero(job_db):
    job_id = db.enqueue_job("convert", video_id=1, version_id=2)
    db.claim_job()
    db.set_job_progress(job_id, 0.9)
    db.requeue_job(job_id)
    claimed = db.claim_job()
    assert claimed["id"] == job_id
    assert claimed["progress"] == 0


def test_active_jobs_splits_running_from_queued(job_db):
    running_id = db.enqueue_job("convert", video_id=1, version_id=1)
    db.claim_job()
    db.set_job_progress(running_id, 0.3)
    db.enqueue_job("convert", video_id=2, version_id=2)

    snapshot = db.active_jobs()
    assert [job["id"] for job in snapshot["running"]] == [running_id]
    assert snapshot["running"][0]["progress"] == 0.3
    assert [job["video_id"] for job in snapshot["queued"]] == [2]
    assert snapshot["queued"][0]["progress"] is None
    assert snapshot["queued_total"] == 1


def test_active_jobs_excludes_normalize(job_db):
    db.enqueue_job("normalize", video_id=5, version_id=0)
    snapshot = db.active_jobs()
    assert snapshot["queued"] == []
    assert snapshot["queued_total"] == 0


def test_active_jobs_caps_queued_but_counts_all(job_db):
    for video_id in range(1, 26):
        db.enqueue_job("convert", video_id=video_id, version_id=video_id)
    snapshot = db.active_jobs(queued_limit=20)
    assert len(snapshot["queued"]) == 20
    assert snapshot["queued_total"] == 25


def test_active_jobs_orders_queued_by_priority_then_id(job_db):
    db.enqueue_job("convert", video_id=1, version_id=1, priority=db.PRIORITY_BULK)
    db.enqueue_job("convert", video_id=2, version_id=2, priority=db.PRIORITY_INTERACTIVE)
    snapshot = db.active_jobs()
    assert [job["video_id"] for job in snapshot["queued"]] == [2, 1]


def test_active_jobs_carries_the_video_title(job_db):
    video_id = db.add_video("https://example.com/a", platform="youtube", title="Blade Runner")
    db.enqueue_job("convert", video_id=video_id, version_id=1)
    snapshot = db.active_jobs()
    assert snapshot["queued"][0]["title"] == "Blade Runner"
```

If `tests/test_jobs.py` has no `get_job` helper in `db`, note that one already exists (`db.py` around line 1324, `SELECT * FROM jobs WHERE id = ?`). If the fixture in that file is named something other than `job_db`, use the existing name — do not add a second fixture. If `db.add_video`'s signature differs from the call above, match the call used elsewhere in `tests/test_jobs.py` or `tests/test_db.py`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_jobs.py -v -k "progress or active_jobs"`
Expected: FAIL — `AttributeError: module 'db' has no attribute 'set_job_progress'`

- [ ] **Step 3: Implement**

In `db.py`, inside `init_db`, after the `jobs` table `executescript` block (around line 209), add the guard:

```python
        job_columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)").fetchall()}
        # Fraction 0..1 written by the converter process while ffmpeg runs. NULL
        # until a job is claimed; SQLite is the only channel between converter.py
        # and the web workers, which is why this lives on the row.
        if "progress" not in job_columns:
            _add_column(conn, "ALTER TABLE jobs ADD COLUMN progress REAL")
```

In `claim_job`, add `progress = 0` to the SET clause so a requeued job restarts its bar:

```python
            UPDATE jobs
            SET status = 'running', started_at = ?, attempts = attempts + 1, progress = 0
```

After `finish_job`, add:

```python
# Kinds whose progress the iOS UI shows. 'normalize' is deliberately absent:
# those rows render as "downloading" in the app, not as a convert spinner.
PROGRESS_JOB_KINDS = ("convert", "hls")


def set_job_progress(job_id: int, fraction: float) -> None:
    """Record how far along a running job's ffmpeg is (0..1)."""
    with _conn() as conn:
        conn.execute("UPDATE jobs SET progress = ? WHERE id = ?", (fraction, job_id))


def active_jobs(queued_limit: int = 20) -> dict:
    """Running jobs, the next `queued_limit` queued ones, and the queued total.

    The queued slice uses claim_job's ordering, so it is genuinely the next work
    up. The cap exists because a bulk Download-all leaves 200+ rows queued and
    this feeds a 2s poll.
    """
    placeholders = ",".join("?" for _ in PROGRESS_JOB_KINDS)
    columns = """
        job.id, job.kind, job.video_id, job.version_id, job.priority, job.progress,
        video.title AS title, video.show_title AS show_title
    """
    with _conn() as conn:
        running = conn.execute(
            f"""
            SELECT {columns} FROM jobs AS job
            LEFT JOIN videos AS video ON video.id = job.video_id
            WHERE job.status = 'running' AND job.kind IN ({placeholders})
            ORDER BY job.id
            """,
            PROGRESS_JOB_KINDS,
        ).fetchall()
        queued = conn.execute(
            f"""
            SELECT {columns} FROM jobs AS job
            LEFT JOIN videos AS video ON video.id = job.video_id
            WHERE job.status = 'queued' AND job.attempts < ? AND job.kind IN ({placeholders})
            ORDER BY job.priority, job.id
            LIMIT ?
            """,
            (MAX_JOB_ATTEMPTS, *PROGRESS_JOB_KINDS, queued_limit),
        ).fetchall()
        total = conn.execute(
            f"""
            SELECT COUNT(*) FROM jobs
            WHERE status = 'queued' AND attempts < ? AND kind IN ({placeholders})
            """,
            (MAX_JOB_ATTEMPTS, *PROGRESS_JOB_KINDS),
        ).fetchone()[0]
    return {
        "running": [dict(row) for row in running],
        "queued": [dict(row) for row in queued],
        "queued_total": total,
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_jobs.py tests/test_db.py -v`
Expected: PASS, including every pre-existing test in both files.

- [ ] **Step 5: Commit**

```bash
git add db.py tests/test_jobs.py
git commit -m "feat: track ffmpeg job progress on the jobs row"
```

---

### Task 3: Route progress through library, hls, and the converter

**Files:**
- Modify: `library.py:164-167` (delete `_run_ffmpeg`), `library.py:169-240` (`convert_library_video`)
- Modify: `hls.py:125-128` (delete `_run_ffmpeg`), `hls.py:199-230` (`build_hls_package`), `hls.py:267-290` (`prepare`)
- Modify: `converter.py:33-59` (handlers), `converter.py:62-85` (`run_job`)
- Test: `tests/test_library.py`, `tests/test_hls.py`, `tests/test_converter.py`

**Interfaces:**
- Consumes: `ffmpeg_progress.run_ffmpeg`, `ffmpeg_progress.probe_duration` (Task 1); `db.set_job_progress` (Task 2).
- Produces:
  - `library.convert_library_video(video_id, version_id=None, *, raise_errors=False, on_progress=None)`
  - `hls.prepare(video_id, source_path, *, raise_errors=False, on_progress=None)`
  - `hls.build_hls_package(..., run_ffmpeg=..., audio_lang=None, on_progress=None)`
  - `converter.JOB_HANDLERS` entries now take `(job, on_progress)`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_library.py`:

```python
def test_convert_library_video_reports_progress(monkeypatch, tmp_path):
    # Follow this file's existing convert test for db/video setup; the assertion
    # below is what is new. `seen` receives fractions from the injected runner.
    seen = []
    captured = {}

    def fake_run_ffmpeg(cmd, *, duration=None, on_progress=None):
        captured["duration"] = duration
        if on_progress:
            on_progress(0.5)

    monkeypatch.setattr(library.ffmpeg_progress, "run_ffmpeg", fake_run_ffmpeg)
    # ... existing setup that produces a transcoding (non-passthrough) plan ...
    library.convert_library_video(video_id, version_id, on_progress=seen.append)
    assert seen == [0.5]
    assert captured["duration"] > 0
```

Add to `tests/test_hls.py`:

```python
def test_build_hls_package_passes_duration_and_progress(tmp_path):
    calls = {}

    def fake_run_ffmpeg(cmd, *, duration=None, on_progress=None):
        calls["duration"] = duration
        if on_progress:
            on_progress(0.25)

    seen = []
    # Reuse this file's existing probe fixture/helper for `probe`.
    hls.build_hls_package(
        1, tmp_path / "source.mkv", output_root=tmp_path,
        probe=probe, subtitles=[], run_ffmpeg=fake_run_ffmpeg,
        on_progress=seen.append,
    )
    assert calls["duration"] == pytest.approx(hls._duration(probe))
    assert seen == [0.25]
```

Add to `tests/test_converter.py`:

```python
def test_run_job_writes_progress_to_the_job_row(monkeypatch, job_db):
    job_id = db.enqueue_job("convert", video_id=1, version_id=1)
    job = db.claim_job()

    def fake_convert(video_id, version_id, *, raise_errors=False, on_progress=None):
        on_progress(0.75)

    monkeypatch.setattr(converter.library, "convert_library_video", fake_convert)
    converter.run_job(job)
    assert db.get_job(job_id)["progress"] == 0.75


def test_run_job_still_marks_failures(monkeypatch, job_db):
    # Regression guard: adding the callback must not swallow handler exceptions.
    job_id = db.enqueue_job("convert", video_id=1, version_id=1)
    job = db.claim_job()

    def boom(*args, **kwargs):
        raise RuntimeError("nope")

    monkeypatch.setattr(converter.library, "convert_library_video", boom)
    converter.run_job(job)
    row = db.get_job(job_id)
    assert row["status"] == "failed"
    assert "nope" in row["error_msg"]
```

Match each file's existing fixture names and setup helpers rather than inventing new ones.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_library.py tests/test_hls.py tests/test_converter.py -v`
Expected: FAIL — `TypeError: convert_library_video() got an unexpected keyword argument 'on_progress'`

- [ ] **Step 3: Implement**

`library.py` — delete `_run_ffmpeg` (lines 164-167), add `import ffmpeg_progress` at the top, and in `convert_library_video`:

```python
def convert_library_video(
    video_id: int,
    version_id: int | None = None,
    *,
    raise_errors: bool = False,
    on_progress=None,
) -> None:
```

then replace the `_run_ffmpeg(cmd)` call with:

```python
        ffmpeg_progress.run_ffmpeg(
            cmd,
            duration=ffmpeg_progress.probe_duration(probe),
            on_progress=on_progress,
        )
```

The passthrough branch returns before this, so it reports nothing — correct, it runs no ffmpeg.

`hls.py` — delete `_run_ffmpeg` (lines 125-128), add `import ffmpeg_progress`, change the `build_hls_package` default and signature:

```python
def build_hls_package(
    video_id: int,
    source_path,
    output_root: Path | None = None,
    *,
    probe: dict | None = None,
    subtitles: list[SubtitleTrack] | None = None,
    run_ffmpeg=ffmpeg_progress.run_ffmpeg,
    audio_lang: str | None = None,
    on_progress=None,
) -> HlsPackage:
```

and the call site inside it:

```python
    run_ffmpeg(
        build_ffmpeg_command(source, out_dir, plan),
        duration=_duration(probe),
        on_progress=on_progress,
    )
```

`hls.prepare` gains `on_progress=None` and forwards it:

```python
def prepare(video_id: int, source_path, *, raise_errors: bool = False, on_progress=None) -> None:
    ...
        build_hls_package(video_id, source_path, audio_lang=audio_lang, on_progress=on_progress)
```

Any existing test that injects `run_ffmpeg=` must accept the new keyword arguments — update those fakes to `def fake(cmd, *, duration=None, on_progress=None)`.

`converter.py` — handlers take the callback:

```python
def _handle_convert(job: dict, on_progress) -> None:
    version_id = job.get("version_id") or 0
    if version_id <= 0:
        raise ValueError("convert job requires a positive version_id")
    library.convert_library_video(
        job["video_id"], version_id, raise_errors=True, on_progress=on_progress
    )


def _handle_hls(job: dict, on_progress) -> None:
    payload = job.get("payload") or {}
    hls.prepare(job["video_id"], payload["source_path"], raise_errors=True, on_progress=on_progress)


def _handle_normalize(job: dict, on_progress) -> dict:
    # Out of scope for progress: these rows show as "downloading" in the app.
    from downloader import _normalize_media_for_ios_sync

    payload = job.get("payload") or {}
    output = _normalize_media_for_ios_sync(Path(payload["input_path"]))
    return {"output_path": str(output)}
```

and in `run_job`, replace `result = handler(job)` with:

```python
        result = handler(job, lambda fraction: db.set_job_progress(job["id"], fraction))
```

- [ ] **Step 4: Run the full backend suite**

Run: `python -m pytest tests/ -v`
Expected: PASS. The `run_ffmpeg=` fakes in `tests/test_hls.py` are the likely breakage — fix their signatures, don't weaken the assertions.

- [ ] **Step 5: Commit**

```bash
git add library.py hls.py converter.py tests/
git commit -m "feat: report ffmpeg progress from convert and hls jobs"
```

---

### Task 4: `GET /api/jobs`

**Files:**
- Modify: `router.py` (near the other `/api/...` endpoints, e.g. after `api_prepare_video` around line 1093)
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `db.active_jobs` (Task 2).
- Produces: `GET /api/jobs` → `{"running": [...], "queued": [...], "queued_total": int}`, each job
  `{"id", "kind", "video_id", "version_id", "priority", "progress", "title", "show_title"}`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py`:

```python
def test_jobs_requires_a_token(client):
    assert client.get("/api/jobs").status_code == 401


def test_jobs_returns_running_and_queued(client, auth_headers):
    import db
    running_id = db.enqueue_job("convert", video_id=1, version_id=1)
    db.claim_job()
    db.set_job_progress(running_id, 0.6)
    db.enqueue_job("convert", video_id=2, version_id=2)

    body = client.get("/api/jobs", headers=auth_headers).json()
    assert [job["id"] for job in body["running"]] == [running_id]
    assert body["running"][0]["progress"] == 0.6
    assert body["running"][0]["kind"] == "convert"
    assert [job["video_id"] for job in body["queued"]] == [2]
    assert body["queued"][0]["progress"] is None
    assert body["queued_total"] == 1


def test_jobs_caps_the_queued_list_at_twenty(client, auth_headers):
    import db
    for video_id in range(1, 26):
        db.enqueue_job("convert", video_id=video_id, version_id=video_id)
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert len(body["queued"]) == 20
    assert body["queued_total"] == 25


def test_jobs_is_empty_when_nothing_is_pending(client, auth_headers):
    body = client.get("/api/jobs", headers=auth_headers).json()
    assert body == {"running": [], "queued": [], "queued_total": 0}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m pytest tests/test_api.py -v -k jobs`
Expected: FAIL — 404 instead of 401/200.

- [ ] **Step 3: Implement**

In `router.py`:

```python
# The next 20 queued jobs is plenty for a UI list; the bulk Download-all path
# can leave 200+ behind it, and this endpoint is polled every 2s.
JOBS_QUEUED_LIMIT = 20


@router.get("/api/jobs")
async def api_jobs(request: Request):
    """Active ffmpeg work, for the iOS conversion spinners and Downloads list."""
    _check_token(request)
    return db.active_jobs(queued_limit=JOBS_QUEUED_LIMIT)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python -m pytest tests/test_api.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: expose active ffmpeg jobs at GET /api/jobs"
```

---

### Task 5: Swift job models and `APIClient.jobs()`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ConversionJob.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift` (the `VideoAPI` protocol around line 20-40; `prepare`/`video` methods around line 193)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientJobsTests.swift`

**Interfaces:**
- Consumes: the `/api/jobs` shape from Task 4.
- Produces:
  - `public struct ConversionJob: Decodable, Equatable, Identifiable, Sendable` — `id: Int`, `videoID: Int`, `versionID: Int?`, `kind: String`, `progress: Double?`, `title: String?`, `showTitle: String?`.
  - `public struct JobsSnapshot: Decodable, Equatable, Sendable` — `running: [ConversionJob]`, `queued: [ConversionJob]`, `queuedTotal: Int`; `public static let empty`.
  - `public enum ConversionState: Equatable, Sendable { case running(Double); case queued }`
  - `public protocol JobsAPI: Sendable { func jobs() async throws -> JobsSnapshot }`
  - `APIClient.jobs() async throws -> JobsSnapshot`, `APIClient: JobsAPI`.

- [ ] **Step 1: Write the failing test**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientJobsTests.swift`:

```swift
import Testing
import Foundation
@testable import PatataTubeKit

@Suite(.serialized)
struct APIClientJobsTests {
    private func makeClient() -> APIClient {
        let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: "tok")
        return APIClient(store: store, session: mockSession())
    }

    @Test func fetchesRunningAndQueuedJobs() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/jobs")
            let body = """
            {"running":[{"id":41,"kind":"convert","video_id":812,"version_id":3,
                         "priority":100,"progress":0.47,"title":"Blade Runner",
                         "show_title":null}],
             "queued":[{"id":42,"kind":"hls","video_id":813,"version_id":4,
                        "priority":0,"progress":null,"title":"Dune","show_title":null}],
             "queued_total":203}
            """.data(using: .utf8)!
            return (jsonResponse(req.url!), body)
        }
        let snapshot = try await makeClient().jobs()
        #expect(snapshot.running.count == 1)
        #expect(snapshot.running[0].videoID == 812)
        #expect(snapshot.running[0].progress == 0.47)
        #expect(snapshot.queued[0].progress == nil)
        #expect(snapshot.queued[0].title == "Dune")
        #expect(snapshot.queuedTotal == 203)
    }

    @Test func decodesAnEmptySnapshot() async throws {
        MockURLProtocol.handler = { req in
            let body = #"{"running":[],"queued":[],"queued_total":0}"#.data(using: .utf8)!
            return (jsonResponse(req.url!), body)
        }
        let snapshot = try await makeClient().jobs()
        #expect(snapshot == .empty)
    }
}
```

`InMemoryCredentialStore`, `mockSession()` and `jsonResponse(_:)` already exist in `MockURLProtocol.swift` / `APIClientReadTests.swift` — reuse them exactly as the read tests do.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientJobsTests`
Expected: FAIL to compile — `value of type 'APIClient' has no member 'jobs'`

- [ ] **Step 3: Implement**

Create `ConversionJob.swift`:

```swift
import Foundation

/// One unit of server-side ffmpeg work, as reported by GET /api/jobs.
/// `progress` is nil while the job is still queued -- the UI shows an
/// indeterminate spinner for those and a determinate ring once it is a number.
public struct ConversionJob: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let videoID: Int
    public let versionID: Int?
    public let kind: String
    public let progress: Double?
    public let title: String?
    public let showTitle: String?

    public init(
        id: Int, videoID: Int, versionID: Int?, kind: String,
        progress: Double?, title: String?, showTitle: String?
    ) {
        self.id = id
        self.videoID = videoID
        self.versionID = versionID
        self.kind = kind
        self.progress = progress
        self.title = title
        self.showTitle = showTitle
    }
}

public struct JobsSnapshot: Decodable, Equatable, Sendable {
    public let running: [ConversionJob]
    public let queued: [ConversionJob]
    public let queuedTotal: Int

    public init(running: [ConversionJob], queued: [ConversionJob], queuedTotal: Int) {
        self.running = running
        self.queued = queued
        self.queuedTotal = queuedTotal
    }

    public static let empty = JobsSnapshot(running: [], queued: [], queuedTotal: 0)
}

public enum ConversionState: Equatable, Sendable {
    case running(Double)
    case queued
}

/// Narrower than VideoAPI on purpose: JobsStore needs one call, and its tests
/// should not have to stub twenty unrelated methods.
public protocol JobsAPI: Sendable {
    func jobs() async throws -> JobsSnapshot
}
```

In `APIClient.swift`, add `func jobs() async throws -> JobsSnapshot` to the `VideoAPI` protocol, declare `extension APIClient: JobsAPI {}` (or add `JobsAPI` to its conformance list), and implement next to `prepare`:

```swift
    public func jobs() async throws -> JobsSnapshot {
        let data = try await authedGet("api/jobs")
        do { return try Self.makeDecoder().decode(JobsSnapshot.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }
```

`makeDecoder()` already uses `.convertFromSnakeCase`, so `video_id` → `videoID` and `queued_total` → `queuedTotal` need no `CodingKeys`.

Every existing `VideoAPI` conformer in the test suites now needs a `jobs()` stub — add `func jobs() async throws -> JobsSnapshot { .empty }` to each until the package compiles.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientJobsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/ConversionJob.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/
git commit -m "feat: add ConversionJob model and APIClient.jobs()"
```

---

### Task 6: `JobsStore`

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/JobsStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/JobsStoreTests.swift`

**Interfaces:**
- Consumes: `JobsAPI`, `JobsSnapshot`, `ConversionState` (Task 5).
- Produces: `@MainActor @Observable public final class JobsStore` with
  - `init(api: JobsAPI, pollIntervalSeconds: Double = 2.0, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })`
  - `private(set) var snapshot: JobsSnapshot`
  - `func subscribe()`, `func unsubscribe()`
  - `func state(videoID: Int) -> ConversionState?`
  - `func refreshNow() async`

- [ ] **Step 1: Write the failing tests**

Create `ios/PatataTubeKit/Tests/PatataTubeKitTests/JobsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import PatataTubeKit

private actor StubJobsAPI: JobsAPI {
    private var snapshots: [JobsSnapshot]
    private(set) var callCount = 0

    init(_ snapshots: [JobsSnapshot]) { self.snapshots = snapshots }

    func jobs() async throws -> JobsSnapshot {
        callCount += 1
        return snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? .empty)
    }

    func calls() -> Int { callCount }
}

private func job(id: Int, videoID: Int, progress: Double?) -> ConversionJob {
    ConversionJob(id: id, videoID: videoID, versionID: nil, kind: "convert",
                  progress: progress, title: "Video \(videoID)", showTitle: nil)
}

@Suite("Jobs store")
@MainActor
struct JobsStoreTests {
    @Test func refreshNowPublishesTheSnapshot() async {
        let snapshot = JobsSnapshot(running: [job(id: 1, videoID: 9, progress: 0.5)],
                                    queued: [], queuedTotal: 0)
        let store = JobsStore(api: StubJobsAPI([snapshot]))
        await store.refreshNow()
        #expect(store.snapshot == snapshot)
    }

    @Test func stateIsRunningWithProgressForARunningJob() async {
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [job(id: 1, videoID: 9, progress: 0.42)],
                         queued: [], queuedTotal: 0)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 9) == .running(0.42))
    }

    @Test func stateIsQueuedForAQueuedJobAndNilForAnythingElse() async {
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [], queued: [job(id: 2, videoID: 7, progress: nil)],
                         queuedTotal: 1)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 7) == .queued)
        #expect(store.state(videoID: 99) == nil)
    }

    @Test func aRunningJobWithoutANumberReadsAsQueued() async {
        // The row is claimed but ffmpeg has not reported yet -- the UI should
        // keep spinning rather than flash 0%.
        let store = JobsStore(api: StubJobsAPI([
            JobsSnapshot(running: [job(id: 1, videoID: 5, progress: nil)],
                         queued: [], queuedTotal: 0)
        ]))
        await store.refreshNow()
        #expect(store.state(videoID: 5) == .queued)
    }

    @Test func subscribingStartsPollingAndUnsubscribingStopsIt() async throws {
        let api = StubJobsAPI([.empty])
        var sleeps = 0
        let store = JobsStore(api: api, sleep: { _ in
            sleeps += 1
            if sleeps > 3 { throw CancellationError() }
        })
        store.subscribe()
        while await api.calls() < 3 { await Task.yield() }
        store.unsubscribe()
        let settled = await api.calls()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await api.calls() == settled)
    }

    @Test func theLoopRunsOnceForOverlappingSubscribers() async {
        let api = StubJobsAPI([.empty])
        let store = JobsStore(api: api, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        store.subscribe()
        store.subscribe()
        while await api.calls() < 2 { await Task.yield() }
        store.unsubscribe()
        // One subscriber remains, so polling continues.
        let before = await api.calls()
        while await api.calls() == before { await Task.yield() }
        store.unsubscribe()
    }

    @Test func aFailedPollKeepsTheLastSnapshot() async {
        struct FailingAPI: JobsAPI {
            func jobs() async throws -> JobsSnapshot { throw APIError.badStatus(500) }
        }
        let snapshot = JobsSnapshot(running: [job(id: 1, videoID: 3, progress: 0.1)],
                                    queued: [], queuedTotal: 0)
        let store = JobsStore(api: StubJobsAPI([snapshot]))
        await store.refreshNow()
        let failing = JobsStore(api: FailingAPI())
        await failing.refreshNow()
        #expect(failing.snapshot == .empty)
        #expect(store.snapshot == snapshot)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter JobsStoreTests`
Expected: FAIL to compile — `cannot find 'JobsStore' in scope`

- [ ] **Step 3: Implement**

Create `JobsStore.swift`:

```swift
import Foundation
import Observation

/// Polls GET /api/jobs while any view needs it, and answers "what is the server
/// doing with this video right now?".
///
/// Single source for both the download button's ring and the Downloads view's
/// Converting section, so the same number never gets fetched two ways. The loop
/// only runs while something is subscribed -- an idle Downloads tab costs
/// nothing.
@MainActor
@Observable
public final class JobsStore {
    public private(set) var snapshot: JobsSnapshot = .empty

    private let api: JobsAPI
    private let pollIntervalSeconds: Double
    private let sleep: @Sendable (Duration) async throws -> Void
    private var subscriberCount = 0
    private var pollTask: Task<Void, Never>?

    public init(
        api: JobsAPI,
        pollIntervalSeconds: Double = 2.0,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.pollIntervalSeconds = pollIntervalSeconds
        self.sleep = sleep
    }

    public func subscribe() {
        subscriberCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                do {
                    try await self.sleep(.seconds(self.pollIntervalSeconds))
                } catch {
                    return
                }
            }
        }
    }

    public func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// A failed poll leaves the previous snapshot in place: a dropped request
    /// should not blank out a ring that is mid-conversion.
    public func refreshNow() async {
        guard let fresh = try? await api.jobs() else { return }
        snapshot = fresh
    }

    /// A running job whose ffmpeg has not reported yet reads as `.queued` so the
    /// UI keeps spinning instead of flashing 0%.
    public func state(videoID: Int) -> ConversionState? {
        if let running = snapshot.running.first(where: { $0.videoID == videoID }) {
            if let progress = running.progress, progress > 0 { return .running(progress) }
            return .queued
        }
        if snapshot.queued.contains(where: { $0.videoID == videoID }) { return .queued }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter JobsStoreTests`
Expected: PASS

Then run both configurations, since the package's `DEVLOG` gating requires it:
`swift test` and `swift test -c release`. Ignore the pre-existing `Fatal error: Index out of range` from a full parallel run and any pre-existing `VideoStoreTests` flake — re-run filtered before concluding anything broke.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/JobsStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/JobsStoreTests.swift
git commit -m "feat: add JobsStore polling active conversions"
```

---

### Task 7: Determinate ring on the download button

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadButton.swift:205-214` (the `control` builder)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:186` (state) and wherever it injects `preparationTracker` into the environment
- Test: `ios/PatataTube/Tests/DownloadButtonTests.swift`

**Interfaces:**
- Consumes: `JobsStore`, `ConversionState` (Task 6).
- Produces: `ConversionRing` view; `DownloadButton` reads `@Environment(JobsStore.self)`.

- [ ] **Step 1: Write the failing test**

Add to `ios/PatataTube/Tests/DownloadButtonTests.swift`, following the file's existing ViewInspector setup:

```swift
    @Test func showsThePercentWhileConverting() async throws {
        let store = JobsStore(api: StubJobsAPI(running: 9, progress: 0.47))
        await store.refreshNow()
        let sut = DownloadButton(
            identity: DownloadButtonIdentity(videoID: 9, versionID: nil, audioLanguage: nil),
            currentCacheState: { .notCached },
            onDownload: { true },
            onCancel: {},
            onDeleteCache: {}
        ).environment(store)
        let text = try sut.inspect().find(text: "47%")
        #expect(try text.string() == "47%")
    }

    @Test func showsNoPercentWhileQueued() async throws {
        let store = JobsStore(api: StubJobsAPI(queued: 9))
        await store.refreshNow()
        let sut = DownloadButton(
            identity: DownloadButtonIdentity(videoID: 9, versionID: nil, audioLanguage: nil),
            currentCacheState: { .notCached },
            onDownload: { true },
            onCancel: {},
            onDeleteCache: {}
        ).environment(store)
        #expect(throws: (any Error).self) { try sut.inspect().find(ViewType.Text.self) }
    }
```

Add a small `StubJobsAPI` helper to that test file with `init(running:progress:)` and `init(queued:)` convenience initializers producing the matching `JobsSnapshot`.

- [ ] **Step 2: Build to verify it fails**

Run the app test target from Xcode (⌘U) or `xcodebuild test` if a scheme exists.
Expected: FAIL to compile — `DownloadButton` has no `JobsStore` environment value.

- [ ] **Step 3: Implement**

In `DownloadButton.swift`, add the environment read next to the existing tracker:

```swift
    @Environment(JobsStore.self) private var jobsStore: JobsStore?
```

and replace `control`:

```swift
    @ViewBuilder
    private var control: some View {
        // The server may be converting this video even if this device did not
        // ask for it, so the job row counts as much as the local tracker.
        if case .running(let fraction) = jobsStore?.state(videoID: identity.videoID) {
            ConversionRing(fraction: fraction)
        } else if preparationTracker?.isPreparing(videoID: identity.videoID) == true
                    || jobsStore?.state(videoID: identity.videoID) == .queued {
            ProgressView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Preparing video")
        } else {
            cacheControl
        }
    }
```

and add, in the same file:

```swift
/// Determinate ring with the percentage inside, sized to the same 44x44 the
/// spinner and the cached checkmark use so nothing shifts when it swaps in.
private struct ConversionRing: View {
    let fraction: Double

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .progressViewStyle(.circular)
            .overlay {
                Text("\(Int((min(max(fraction, 0), 1)) * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("Converting, \(Int(fraction * 100)) percent")
    }
}
```

On iOS `.circular` `ProgressView(value:)` renders indeterminate in some contexts; if the ring does not draw, use an explicit `Circle().trim(from: 0, to: fraction).stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))` over a `Circle().stroke(.tertiary, lineWidth: 3)` background, keeping the same overlay text and 44×44 frame.

In `VideoGridView.swift`, next to `@State private var preparationTracker`:

```swift
    @State private var jobsStore = JobsStore(api: ...)   // the same APIClient the store uses
```

Get the client from wherever `VideoGridView` already reaches `AppModel`/`VideoStore` for its API — do not construct a second `APIClient`. Inject and drive it alongside the existing tracker injection:

```swift
        .environment(jobsStore)
        .task {
            jobsStore.subscribe()
            defer { jobsStore.unsubscribe() }
            // Hold for the view's lifetime; the task is cancelled on disappear.
            try? await Task.never()
        }
```

If `Task.never()` is unavailable, use `.onAppear { jobsStore.subscribe() } .onDisappear { jobsStore.unsubscribe() }`.

- [ ] **Step 4: Run the tests**

Run the app test target (⌘U). Expected: PASS, including the pre-existing `DownloadButtonTests`.
Also run `cd ios/PatataTubeKit && swift test` — nothing in the package should have changed behavior.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/DownloadButton.swift \
        ios/PatataTube/Sources/VideoGridView.swift \
        ios/PatataTube/Tests/DownloadButtonTests.swift
git commit -m "feat: show conversion percent on the download button"
```

---

### Task 8: "Converting" section in the Downloads view

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadsView.swift:12-53`
- Test: `ios/PatataTube/Tests/DownloadsViewTests.swift`

**Interfaces:**
- Consumes: `JobsStore`, `ConversionJob`, `JobsSnapshot` (Tasks 5-6).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing tests**

Add to `ios/PatataTube/Tests/DownloadsViewTests.swift`:

```swift
    @Test func listsConvertingJobsWithTheirPercent() async throws {
        let store = JobsStore(api: StubJobsAPI(snapshot: JobsSnapshot(
            running: [ConversionJob(id: 1, videoID: 7, versionID: nil, kind: "convert",
                                    progress: 0.47, title: "Blade Runner", showTitle: nil)],
            queued: [ConversionJob(id: 2, videoID: 8, versionID: nil, kind: "convert",
                                   progress: nil, title: "Dune", showTitle: nil)],
            queuedTotal: 1)))
        await store.refreshNow()
        let sut = DownloadsView(
            active: { [] }, recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in }, onPlay: { _ in }
        ).environment(store).environmentObject(AppModel.preview)

        #expect(throws: Never.self) { try sut.inspect().find(text: "Converting") }
        #expect(throws: Never.self) { try sut.inspect().find(text: "47%") }
        #expect(throws: Never.self) { try sut.inspect().find(text: "Dune") }
    }

    @Test func showsTheOverflowCountWhenTheQueueIsCapped() async throws {
        let queued = (1...20).map {
            ConversionJob(id: $0, videoID: $0, versionID: nil, kind: "convert",
                          progress: nil, title: "Video \($0)", showTitle: nil)
        }
        let store = JobsStore(api: StubJobsAPI(snapshot: JobsSnapshot(
            running: [], queued: queued, queuedTotal: 203)))
        await store.refreshNow()
        let sut = DownloadsView(
            active: { [] }, recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in }, onPlay: { _ in }
        ).environment(store).environmentObject(AppModel.preview)

        #expect(throws: Never.self) { try sut.inspect().find(text: "+183 more") }
    }

    @Test func hidesTheConvertingSectionWhenNothingIsConverting() async throws {
        let store = JobsStore(api: StubJobsAPI(snapshot: .empty))
        await store.refreshNow()
        let sut = DownloadsView(
            active: { [] }, recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in }, onPlay: { _ in }
        ).environment(store).environmentObject(AppModel.preview)

        #expect(throws: (any Error).self) { try sut.inspect().find(text: "Converting") }
    }
```

Use whatever this file already uses to supply `AppModel` — if there is no `AppModel.preview`, follow the existing tests' construction exactly.

- [ ] **Step 2: Build to verify it fails**

Run the app test target (⌘U). Expected: FAIL — no "Converting" text in the view.

- [ ] **Step 3: Implement**

In `DownloadsView.swift`, add `@Environment(JobsStore.self) private var jobsStore: JobsStore?` and insert the section above `In Progress`:

```swift
                let snapshot = jobsStore?.snapshot ?? .empty
                let converting = snapshot.running + snapshot.queued
                if !converting.isEmpty {
                    Section("Converting") {
                        ForEach(converting) { job in
                            convertingRow(job)
                        }
                        // The server sends at most 20 queued rows; the rest is a count.
                        if snapshot.queuedTotal > snapshot.queued.count {
                            Text("+\(snapshot.queuedTotal - snapshot.queued.count) more")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
```

and the row builder next to `activeRow`:

```swift
    private func convertingRow(_ job: ConversionJob) -> some View {
        let rowVideo = video(job.videoID, job.versionID)
        return HStack {
            thumbnail(rowVideo)
            Text(rowVideo?.title ?? job.title ?? "Video \(job.videoID)")
            Spacer()
            if let progress = job.progress, progress > 0 {
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.circular)
                    .frame(width: 22, height: 22)
            } else {
                ProgressView().frame(width: 22, height: 22)
            }
        }
        .accessibilityElement(children: .combine)
    }
```

Subscribe the store for the view's lifetime the same way `VideoGridView` does in Task 7, so the Downloads tab keeps the numbers fresh when it is the only thing on screen:

```swift
        .onAppear { jobsStore?.subscribe() }
        .onDisappear { jobsStore?.unsubscribe() }
```

Note `TimelineView(.periodic(by: 0.25))` already redraws the list; `JobsStore` refreshes the data underneath every 2s.

- [ ] **Step 4: Run the tests**

Run the app test target (⌘U). Expected: PASS, including the pre-existing Downloads tests.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/DownloadsView.swift ios/PatataTube/Tests/DownloadsViewTests.swift
git commit -m "feat: list converting videos in the Downloads view"
```

---

### Task 9: Document the feature

**Files:**
- Modify: `CLAUDE.md` (the "ffmpeg runs in exactly one process" section)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Update CLAUDE.md**

In the "ffmpeg runs in exactly one process" section, after the queue-depth log sample, add:

```markdown
`ffmpeg_progress.run_ffmpeg` is the only place that spawns ffmpeg's subprocess.
It appends `-progress pipe:1 -nostats` when given a duration and a callback,
and writes a 0..1 fraction to `jobs.progress` (throttled to ≥1% or ≥2s). stderr
gets its own pipe drained on a thread — merging it into stdout would corrupt the
progress stream, and not draining it deadlocks a verbose failure.

`GET /api/jobs` exposes running jobs plus the next 20 queued (`convert` and
`hls` only; `normalize` is excluded) with a `queued_total`. The iOS `JobsStore`
polls it every 2s while any view is subscribed, and both the download button's
determinate ring and the Downloads view's "Converting" section read from it.
```

- [ ] **Step 2: Verify the whole suite**

Run: `python -m pytest tests/ -v`
Run: `cd ios/PatataTubeKit && swift test`
Run: `cd ios/PatataTubeKit && swift test -c release`
Expected: PASS (modulo the documented pre-existing full-parallel-run flakes).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: describe ffmpeg progress reporting"
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| `ffmpeg_progress.py` runner, stderr split, `duration=None` passthrough | 1 |
| `jobs.progress` guard, `set_job_progress`, `claim_job` reset | 2 |
| Throttling (≥1% or ≥2s) | 1 (`ProgressThrottle`), used in 3 |
| Wiring through library/hls/converter, `normalize` untouched | 3 |
| `GET /api/jobs`, 20-row cap, `queued_total` | 2 (`active_jobs`) + 4 (endpoint) |
| `ConversionJob`/`JobsSnapshot`/`APIClient.jobs()` | 5 |
| `JobsStore` refcounted 2s poll, `state(videoID:)` | 6 |
| Button ring + percent, queued keeps spinner | 7 |
| Downloads "Converting" section, `+N more` footer | 8 |
| Test list (parser, stderr, db, endpoint, store, button, view) | 1-8 |

**Types are consistent across tasks:** `progress` is `float`/`Double?` in 0…1 everywhere; `active_jobs` returns exactly the keys `ConversionJob` decodes; `ConversionState` is produced only by `JobsStore.state(videoID:)` and consumed in Tasks 7 and 8.

**Known follow-on:** Task 5 changes the `VideoAPI` protocol, so every stub conformer in the existing Swift test suites needs a `jobs()` method. That is called out in Task 5, Step 3.
