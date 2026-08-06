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

    with subprocess.Popen(
        full_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    ) as proc:

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
