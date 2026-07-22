# Caddy Direct-Request STDOUT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show concise, separately colored `./serve` output only for PatataTube requests that Caddy answers directly from disk.

**Architecture:** Patata's Caddy routes add `served_by: caddy` to access events only on direct `file_server` branches. A small Python follower reads newly appended JSON records from the existing rotating access log, filters and safely formats marked records, and exits when the `./serve` process disappears. The launcher pipes those lines through its existing colorizer with a magenta `caddy` label.

**Tech Stack:** Caddy 2.11 Caddyfile, Bash, Python 3.13 standard library, pytest

## Global Constraints

- Show no Caddy terminal entry for requests proxied to FastAPI.
- Keep the complete JSON access log at `log/caddy_access.log` unchanged except for the new marker field on direct responses.
- Terminal entries contain method, path without query parameters, status, response byte count, and duration.
- Use a magenta `caddy` label in both development and production modes without changing existing stream colors.
- Do not replay historical log entries, and continue across access-log creation and rotation.
- The follower is auxiliary and must not block server startup or survive the server process.
- Do not change routing, authentication, cache behavior, or any non-Patata Caddy site.

## File Structure

- Create `caddy_access.py`: parse, filter, format, and follow Caddy JSON access records; independently testable and standard-library only.
- Create `tests/test_caddy_access.py`: unit and subprocess tests for filtering, safe output, EOF behavior, rotation, and watched-process shutdown.
- Modify `serve`: start the follower on the original stdout and apply the magenta `caddy` label before selecting the existing dev or production server path.
- Modify `../server/Caddyfile`: annotate exactly the four Patata direct-file branches.

---

### Task 1: Filtered Caddy Access-Log Follower

**Files:**
- Create: `caddy_access.py`
- Create: `tests/test_caddy_access.py`

**Interfaces:**
- Consumes: one-line Caddy JSON access records containing optional root field `served_by`; access-log path and optional watched PID from CLI.
- Produces: `format_entry(line: str) -> str | None`, `follow(path: Path, watch_pid: int | None, poll_interval: float = 0.1) -> Iterator[str]`, and CLI lines formatted as `METHOD /path STATUS SIZEB DURATIONms`.

- [ ] **Step 1: Write failing formatter tests**

Create `tests/test_caddy_access.py` with imports and these tests:

```python
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

import caddy_access


def _entry(*, marked=True, uri="/assets/app.js?token=secret"):
    entry = {
        "request": {"method": "GET", "uri": uri},
        "status": 200,
        "size": 1536,
        "duration": 0.01234,
    }
    if marked:
        entry["served_by"] = "caddy"
    return json.dumps(entry)


def test_format_entry_formats_marked_request_without_query():
    assert caddy_access.format_entry(_entry()) == "GET /assets/app.js 200 1536B 12.3ms"


def test_format_entry_ignores_unmarked_and_malformed_records():
    assert caddy_access.format_entry(_entry(marked=False)) is None
    assert caddy_access.format_entry("not json") is None


def test_format_entry_uses_safe_defaults_for_partial_record():
    line = json.dumps({"served_by": "caddy", "request": {"uri": "/favicon.ico"}})
    assert caddy_access.format_entry(line) == "- /favicon.ico - 0B 0.0ms"
```

- [ ] **Step 2: Run formatter tests and verify they fail**

Run: `rtk pytest tests/test_caddy_access.py -q`

Expected: collection fails with `ModuleNotFoundError: No module named 'caddy_access'`.

- [ ] **Step 3: Implement parsing and formatting**

Create `caddy_access.py` with:

```python
#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import time
from typing import Iterator
from urllib.parse import urlsplit


def format_entry(line: str) -> str | None:
    try:
        entry = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(entry, dict):
        return None
    if entry.get("served_by") != "caddy":
        return None

    request = entry.get("request") or {}
    method = request.get("method", "-")
    path = urlsplit(request.get("uri", "/")).path or "/"
    status = entry.get("status", "-")
    size = entry.get("size", 0)
    duration_ms = entry.get("duration", 0) * 1000
    return f"{method} {path} {status} {size}B {duration_ms:.1f}ms"
```

- [ ] **Step 4: Run formatter tests and verify they pass**

Run: `rtk pytest tests/test_caddy_access.py -q`

Expected: `3 passed`.

- [ ] **Step 5: Write failing follow, rotation, and lifecycle tests**

Append to `tests/test_caddy_access.py`:

```python
def _start_follower(log_path: Path, watch_pid: int):
    return subprocess.Popen(
        [
            sys.executable,
            "-u",
            "caddy_access.py",
            str(log_path),
            "--watch-pid",
            str(watch_pid),
            "--poll-interval",
            "0.01",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _read_line(process, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        readable, _, _ = select.select([process.stdout], [], [], remaining)
        if readable:
            return process.stdout.readline().rstrip("\n")
    raise AssertionError("follower did not emit a line")


def test_cli_skips_history_filters_proxy_and_follows_rotation(tmp_path):
    log_path = tmp_path / "caddy_access.log"
    log_path.write_text(_entry(uri="/assets/old.js") + "\n")
    process = _start_follower(log_path, os.getpid())
    try:
        time.sleep(0.05)
        with log_path.open("a") as stream:
            stream.write(_entry(marked=False, uri="/api/videos") + "\n")
            stream.write(_entry(uri="/assets/new.js?token=hidden") + "\n")
            stream.flush()
        assert _read_line(process) == "GET /assets/new.js 200 1536B 12.3ms"

        rotated = tmp_path / "caddy_access.log.1"
        log_path.rename(rotated)
        log_path.write_text(_entry(uri="/videos/42.mp4") + "\n")
        assert _read_line(process) == "GET /videos/42.mp4 200 1536B 12.3ms"
    finally:
        process.terminate()
        process.wait(timeout=2)


def test_cli_reads_from_start_when_log_is_created_after_start(tmp_path):
    log_path = tmp_path / "later.log"
    process = _start_follower(log_path, os.getpid())
    try:
        time.sleep(0.05)
        log_path.write_text(_entry(uri="/favicon.ico") + "\n")
        assert _read_line(process) == "GET /favicon.ico 200 1536B 12.3ms"
    finally:
        process.terminate()
        process.wait(timeout=2)


def test_cli_exits_when_watched_process_exits(tmp_path):
    watched = subprocess.Popen(["sleep", "30"])
    process = _start_follower(tmp_path / "missing.log", watched.pid)
    watched.terminate()
    watched.wait(timeout=2)
    assert process.wait(timeout=2) == 0
```

- [ ] **Step 6: Run the new tests and verify they fail**

Run: `rtk pytest tests/test_caddy_access.py -q`

Expected: the three CLI tests fail because `caddy_access.py` has no CLI or follower yet.

- [ ] **Step 7: Implement following, rotation, PID watching, and CLI output**

Append to `caddy_access.py`:

```python
def _process_exists(pid: int | None) -> bool:
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def follow(
    path: Path,
    watch_pid: int | None,
    poll_interval: float = 0.1,
) -> Iterator[str]:
    start_at_end = path.exists()
    stream = None
    try:
        while _process_exists(watch_pid):
            if stream is None:
                try:
                    stream = path.open()
                except FileNotFoundError:
                    time.sleep(poll_interval)
                    continue
                if start_at_end:
                    stream.seek(0, os.SEEK_END)
                start_at_end = False

            line = stream.readline()
            if line:
                formatted = format_entry(line)
                if formatted is not None:
                    yield formatted
                continue

            try:
                rotated = os.fstat(stream.fileno()).st_ino != path.stat().st_ino
            except FileNotFoundError:
                rotated = True
            if rotated:
                stream.close()
                stream = None
            time.sleep(poll_interval)
    finally:
        if stream is not None:
            stream.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--watch-pid", type=int)
    parser.add_argument("--poll-interval", type=float, default=0.1)
    args = parser.parse_args()
    for line in follow(args.path, args.watch_pid, args.poll_interval):
        print(line, flush=True)


if __name__ == "__main__":
    main()
```

- [ ] **Step 8: Run focused tests and commit the follower**

Run: `rtk pytest tests/test_caddy_access.py -q`

Expected: `6 passed`.

Run: `rtk git add caddy_access.py tests/test_caddy_access.py && rtk git commit -m "feat: follow direct Caddy access events"`

Expected: one commit containing only the helper and its tests.

---

### Task 2: Wire the Follower into `./serve`

**Files:**
- Modify: `serve:8-24`
- Test: `tests/test_caddy_access.py`

**Interfaces:**
- Consumes: `caddy_access.py PATH --watch-pid PID`, `CADDY_ACCESS_LOG` override, existing `colorize COLOR LABEL` Bash function.
- Produces: magenta ANSI label `caddy  |` on original stdout in both `DEV=1` and Gunicorn modes.

- [ ] **Step 1: Add a failing launcher wiring test**

Append to `tests/test_caddy_access.py`:

```python
def test_serve_wires_caddy_follower_before_dev_and_production_branches():
    source = Path("serve").read_text()
    start = source.index('"$LOG_PYTHON_BIN" -u caddy_access.py')
    dev_branch = source.index('if [ "$DEV" = "1" ]')
    assert start < dev_branch
    assert 'CADDY_ACCESS_LOG="${CADDY_ACCESS_LOG:-log/caddy_access.log}"' in source
    assert 'colorize 35 caddy >&3' in source
    assert '--watch-pid "$$"' in source
```

- [ ] **Step 2: Run the launcher test and verify it fails**

Run: `rtk pytest tests/test_caddy_access.py::test_serve_wires_caddy_follower_before_dev_and_production_branches -q`

Expected: FAIL because the follower command is absent.

- [ ] **Step 3: Start the follower on the preserved stdout**

In `serve`, add the following settings after `PYTHON_BIN`, keep `colorize` unchanged, then move `exec 3>&1` above the dev branch and start the follower:

```bash
CADDY_ACCESS_LOG="${CADDY_ACCESS_LOG:-log/caddy_access.log}"
LOG_PYTHON_BIN="${LOG_PYTHON_BIN:-$PYTHON_BIN}"

# fd 3 preserves the real stdout so Caddy lines bypass the dev/web labels.
exec 3>&1
"$LOG_PYTHON_BIN" -u caddy_access.py \
  "$CADDY_ACCESS_LOG" \
  --watch-pid "$$" \
  | colorize 35 caddy >&3 &
```

Remove the later duplicate `exec 3>&1` from the production section. Leave both server `exec` calls intact so the watched shell PID becomes the Uvicorn or Gunicorn PID and the follower exits when that server exits.

- [ ] **Step 4: Verify launcher syntax, wiring, and all follower tests**

Run: `rtk proxy bash -n serve`

Expected: exit 0 with no output.

Run: `rtk pytest tests/test_caddy_access.py -q`

Expected: `7 passed`.

- [ ] **Step 5: Commit launcher integration**

Run: `rtk git add serve tests/test_caddy_access.py && rtk git commit -m "feat: show Caddy requests in serve output"`

Expected: one commit containing only `serve` and its focused test update.

---

### Task 3: Mark Only Patata's Direct Caddy Responses

**Files:**
- Modify: `../server/Caddyfile:115-177`

**Interfaces:**
- Consumes: Patata route matchers `/assets/*`, `@rooticons`, and the post-rewrite `@served` matchers for HLS and MP4 files.
- Produces: root access-log field `served_by: "caddy"` only when a request reaches one of those four `file_server` branches.

- [ ] **Step 1: Run a failing structural assertion**

Run:

```bash
rtk proxy python3 - <<'PY'
from pathlib import Path

text = Path("../server/Caddyfile").read_text()
patata = text.split("# patatatube", 1)[1].split("# comunidad-antesis", 1)[0]
assert patata.count("log_append served_by caddy") == 2
assert patata.count("log_append @served served_by caddy") == 2
PY
```

Expected: FAIL with `AssertionError` because no direct route is marked yet.

- [ ] **Step 2: Add markers immediately before direct file servers**

Modify only the Patata section:

```caddyfile
handle /assets/* {
	header Cache-Control "public, max-age=3600"
	log_append served_by caddy
	file_server
}
```

```caddyfile
handle @rooticons {
	header Cache-Control "public, max-age=3600"
	log_append served_by caddy
	file_server
}
```

In both the HLS and MP4 routes, add this directly between the `header @served` block and `file_server @served`:

```caddyfile
			log_append @served served_by caddy
			file_server @served
```

Do not add a marker before any `reverse_proxy`.

- [ ] **Step 3: Validate marker placement and Caddy configuration**

Run the structural assertion from Step 1 again.

Expected: exit 0.

Run: `rtk proxy caddy adapt --config ../server/Caddyfile --validate`

Expected: exit 0; adapted JSON is printed and no validation error appears.

- [ ] **Step 4: Commit the shared Caddy configuration in its own repository**

Run: `rtk git -C ../server add Caddyfile && rtk git -C ../server commit -m "feat: mark direct Patata file responses"`

Expected: one commit containing only `Caddyfile`.

---

### Task 4: End-to-End Verification

**Files:**
- Verify only; no planned file changes.

**Interfaces:**
- Consumes: completed Caddy markers, follower, and launcher integration.
- Produces: evidence that direct and proxied routes are correctly distinguished without regressions.

- [ ] **Step 1: Run all automated backend tests**

Run: `rtk pytest tests/`

Expected: all tests pass.

- [ ] **Step 2: Revalidate shell and Caddy configuration**

Run: `rtk proxy bash -n serve`

Expected: exit 0.

Run: `rtk proxy caddy adapt --config ../server/Caddyfile --validate`

Expected: exit 0 with no validation error.

- [ ] **Step 3: Reload Caddy and perform the smoke test**

Run: `rtk proxy caddy reload --config ../server/Caddyfile`

Expected: exit 0 with no output.

Start `./serve`, request `/favicon.ico` and `/api/videos` through port 3050, then inspect its terminal.

Expected: the icon request produces one magenta `caddy` line; the API request appears only in Python's normal access stream. Neither terminal entry exposes query parameters or authorization headers.

- [ ] **Step 4: Confirm clean, scoped diffs**

Run: `rtk git status --short` and `rtk git -C ../server status --short`.

Expected: only the user's pre-existing `plex.py` and `tests/test_plex.py` modifications remain in PatataTube; the server repository is clean.
