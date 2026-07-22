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
