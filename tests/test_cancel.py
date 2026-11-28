import subprocess
import sys
import time

import pytest

import cancel


@pytest.fixture(autouse=True)
def fast_poll(monkeypatch):
    monkeypatch.setattr(cancel, "STOP_POLL_SECONDS", 0.05)


def test_run_kills_the_process_once_should_stop_says_so():
    started = time.monotonic()
    calls = []

    def should_stop():
        calls.append(1)
        return len(calls) >= 2

    with pytest.raises(cancel.Cancelled):
        cancel.run(["sleep", "30"], should_stop, stdout=subprocess.PIPE)
    assert time.monotonic() - started < 5


def test_run_kills_grandchildren_too():
    """yt-dlp runs its own ffmpeg; killing only yt-dlp would leave it writing."""
    marker = "import time; time.sleep(30)"
    script = f"import subprocess, sys; subprocess.run([sys.executable, '-c', {marker!r}])"
    with pytest.raises(cancel.Cancelled):
        cancel.run([sys.executable, "-c", script], lambda: True, stdout=subprocess.PIPE)
    time.sleep(0.2)
    leftover = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True)
    assert leftover.stdout.strip() == ""


def test_run_completes_normally_when_never_stopped():
    proc = cancel.run(["echo", "hi"], lambda: False, stdout=subprocess.PIPE, text=True)
    assert proc.returncode == 0
    assert proc.stdout == "hi\n"


def test_run_ffmpeg_is_stoppable():
    import ffmpeg_progress

    started = time.monotonic()
    with pytest.raises(cancel.Cancelled):
        ffmpeg_progress.run_ffmpeg(["sleep", "30"], should_stop=lambda: True)
    assert time.monotonic() - started < 5
