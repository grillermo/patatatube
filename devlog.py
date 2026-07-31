"""Sink for the iOS app's DEVLOG instrumentation.

A real iPad can't write to the developer's filesystem the way the Simulator can,
so instrumented device builds POST their records here and this module appends
them to ``log/ios.jsonl`` — the same file, in the same JSONL shape, that a
Simulator run writes directly. The coding agent then reads one file regardless of
where the app ran.

See ``ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`` for the producer and
``docs/ios-devlog-instrumentation-plan.md`` for the whole design.
"""

import json
import os
from pathlib import Path

# Records per request and bytes per request. The app batches ~1s of activity, so
# these are generous; anything larger is a bug or an abuse and is rejected rather
# than buffered.
MAX_RECORDS_PER_REQUEST = 512
MAX_REQUEST_BYTES = 1 * 1024 * 1024

# An instrumented app left running all day must not fill the disk. At the cap the
# current file becomes ``ios.jsonl.1`` (replacing any previous one) and a fresh
# file is started, so at most two generations are ever kept.
MAX_LOG_BYTES = 32 * 1024 * 1024


def log_path() -> Path:
    """Read at call time, not import time, so tests can point it elsewhere."""
    return Path(os.getenv("IOS_LOG_FILE", "log/ios.jsonl"))


def _rotate_if_needed(path: Path) -> None:
    try:
        if path.exists() and path.stat().st_size >= MAX_LOG_BYTES:
            os.replace(path, path.with_suffix(path.suffix + ".1"))
    except OSError:
        # Rotation is best effort. Failing to rotate must not lose the records
        # we were asked to store.
        pass


def append(records: list[dict]) -> int:
    """Append records as JSONL. Returns how many were written.

    Blocking; call it off the event loop. Individual records that can't be
    serialised are skipped rather than failing the batch — a malformed record
    must not cost us the well-formed ones around it, which are the context that
    makes it interpretable.
    """
    if not records:
        return 0

    lines = []
    for record in records:
        try:
            # ensure_ascii keeps every record on one line even if a message
            # carries something exotic; separators drop the cosmetic spaces.
            lines.append(json.dumps(record, ensure_ascii=True, separators=(",", ":")))
        except (TypeError, ValueError):
            continue
    if not lines:
        return 0

    path = log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    _rotate_if_needed(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return len(lines)
