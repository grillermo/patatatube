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


def _wait_for_follower_ready(log_path: Path, process, timeout=2.0):
    """Wait until a newly-written record is observed by the follower."""
    deadline = time.monotonic() + timeout
    probe = 0
    while time.monotonic() < deadline:
        probe += 1
        probe_uri = f"/__caddy_follower_ready__/{probe}"
        expected = f"GET {probe_uri} 200 1536B 12.3ms"
        with log_path.open("a") as stream:
            stream.write(_entry(uri=probe_uri) + "\n")
            stream.flush()
        probe_deadline = min(deadline, time.monotonic() + 0.05)
        while time.monotonic() < probe_deadline:
            try:
                line = _read_line(process, timeout=probe_deadline - time.monotonic())
            except AssertionError:
                break
            if line == expected:
                return
            if not line.startswith("GET /__caddy_follower_ready__/"):
                raise AssertionError(f"unexpected follower output while waiting: {line!r}")
    raise AssertionError("follower did not become ready")


def test_cli_skips_history_filters_proxy_and_follows_rotation(tmp_path):
    log_path = tmp_path / "caddy_access.log"
    log_path.write_text(_entry(uri="/assets/old.js") + "\n")
    process = _start_follower(log_path, os.getpid())
    try:
        _wait_for_follower_ready(log_path, process)
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
        _wait_for_follower_ready(log_path, process)
        with log_path.open("a") as stream:
            stream.write(_entry(uri="/favicon.ico") + "\n")
            stream.flush()
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


def test_serve_wires_caddy_follower_before_dev_and_production_branches():
    source = Path("serve").read_text()
    start = source.index('"$LOG_PYTHON_BIN" -u caddy_access.py')
    dev_branch = source.index('if [ "$DEV" = "1" ]')
    assert start < dev_branch
    assert 'CADDY_ACCESS_LOG="${CADDY_ACCESS_LOG:-log/caddy_access.log}"' in source
    assert 'colorize 35 caddy >&3' in source
    assert '--watch-pid "$$"' in source
