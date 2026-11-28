"""Stop a subprocess as soon as its work is no longer wanted.

Deleting a video mid-download has to stop the download, not let it run to the
end and then throw the result away. yt-dlp and ffmpeg block in a subprocess,
so a watcher thread polls `should_stop` and kills the child's whole process
group (yt-dlp spawns its own ffmpeg to merge streams) once it says so.
"""
import os
import signal
import subprocess
import threading
from contextlib import contextmanager
from typing import Callable

STOP_POLL_SECONDS = 1.0


class Cancelled(Exception):
    """The work was stopped because `should_stop` returned True."""


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        proc.kill()


@contextmanager
def kill_when(
    proc: subprocess.Popen,
    should_stop: Callable[[], bool] | None,
    interval: float | None = None,
):
    """Kill `proc` (started with start_new_session=True) once `should_stop()`
    is true, and raise Cancelled on leaving the block if it was killed."""
    if should_stop is None:
        yield
        return
    interval = STOP_POLL_SECONDS if interval is None else interval
    finished = threading.Event()
    stopped = threading.Event()

    def watch() -> None:
        while not finished.wait(interval):
            if proc.poll() is not None:
                return
            try:
                stop = should_stop()
            except Exception:  # noqa: BLE001 - a failed check never kills work
                stop = False
            if stop:
                stopped.set()
                _kill_group(proc)
                return

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        yield
    finally:
        finished.set()
        watcher.join()
    if stopped.is_set():
        raise Cancelled()


def run(
    cmd: list[str], should_stop: Callable[[], bool] | None = None, **kwargs
) -> subprocess.CompletedProcess:
    """subprocess.run, but killed (raising Cancelled) once `should_stop()`."""
    if should_stop is None:
        return subprocess.run(cmd, **kwargs)
    with subprocess.Popen(cmd, start_new_session=True, **kwargs) as proc:
        with kill_when(proc, should_stop):
            stdout, stderr = proc.communicate()
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)
