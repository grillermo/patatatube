import threading
import time
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


def test_handler_raising_marks_job_failed_with_the_message(tmp_db, monkeypatch):
    import converter

    def boom(job, on_progress):
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setitem(converter.JOB_HANDLERS, "hls", boom)
    tmp_db.enqueue_job("hls", video_id=42)

    converter.run_job(tmp_db.claim_job())

    job = tmp_db.get_job(1)
    assert job["status"] == "failed"
    assert "ffmpeg exploded" in job["error_msg"]


def test_run_job_writes_progress_to_the_job_row(tmp_db, monkeypatch):
    import converter

    job_id = tmp_db.enqueue_job("hls", video_id=1, payload={"source_path": "/x.mp4"})
    job = tmp_db.claim_job()

    def fake_prepare(video_id, source_path, *, raise_errors=False, on_progress=None):
        on_progress(0.75)

    monkeypatch.setattr(converter.hls, "prepare", fake_prepare)

    converter.run_job(job)

    assert tmp_db.get_job(job_id)["progress"] == 0.75


def test_run_job_still_marks_failures(tmp_db, monkeypatch):
    """Regression guard: adding the callback must not swallow handler exceptions."""
    import converter

    job_id = tmp_db.enqueue_job("hls", video_id=1, payload={"source_path": "/x.mp4"})
    job = tmp_db.claim_job()

    def boom(*args, **kwargs):
        raise RuntimeError("nope")

    monkeypatch.setattr(converter.hls, "prepare", boom)

    converter.run_job(job)

    row = tmp_db.get_job(job_id)
    assert row["status"] == "failed"
    assert "nope" in row["error_msg"]


def test_hls_failure_resets_video_and_marks_job_failed(tmp_db, monkeypatch, tmp_path):
    import converter
    import hls

    video_id = tmp_db.add_video("https://example.com/video")
    tmp_db.set_hls_status(video_id, "converting")

    def fail_hls(*args, **kwargs):
        raise RuntimeError("hls exploded")

    monkeypatch.setattr(hls, "build_hls_package", fail_hls)
    tmp_db.enqueue_job(
        "hls", video_id=video_id, payload={"source_path": str(tmp_path / "movie.mp4")}
    )

    converter.run_job(tmp_db.claim_job())

    video = tmp_db.get_video(video_id)
    job = tmp_db.get_job(1)
    assert video["hls_status"] == "none"
    assert job["status"] == "failed"
    assert job["error_msg"] == "hls exploded"


def test_handler_result_is_stored_on_the_job(tmp_db, monkeypatch):
    import converter

    monkeypatch.setitem(
        converter.JOB_HANDLERS, "normalize",
        lambda job, on_progress: {"output_path": "/tmp/out.mp4"},
    )
    tmp_db.enqueue_job("normalize", video_id=7)

    converter.run_job(tmp_db.claim_job())

    assert tmp_db.get_job(1)["result"] == {"output_path": "/tmp/out.mp4"}


def test_unknown_kind_fails_the_job_instead_of_crashing_the_runner(tmp_db):
    import converter

    tmp_db.enqueue_job("hls", video_id=1)
    job = tmp_db.claim_job()
    job["kind"] = "bogus"

    converter.run_job(job)

    assert tmp_db.get_job(1)["status"] == "failed"


def test_worker_loop_drains_the_queue_then_idles(tmp_db, monkeypatch):
    import converter

    monkeypatch.setitem(converter.JOB_HANDLERS, "hls", lambda job, on_progress: None)
    for video_id in range(1, 4):
        tmp_db.enqueue_job("hls", video_id=video_id)

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

    def handler(job, on_progress):
        nonlocal concurrent, peak
        with guard:
            concurrent += 1
            peak = max(peak, concurrent)
        time.sleep(0.02)
        with guard:
            concurrent -= 1

    monkeypatch.setitem(converter.JOB_HANDLERS, "hls", handler)
    for video_id in range(1, 21):
        tmp_db.enqueue_job("hls", video_id=video_id)

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


def test_cleanup_orphan_invalidates_partial_hls_output(tmp_db, monkeypatch):
    import converter
    import hls

    invalidated = []
    monkeypatch.setattr(hls, "invalidate", invalidated.append)

    converter.cleanup_orphan({"kind": "hls", "video_id": 42, "payload": None})

    assert invalidated == [42]


def test_normalize_handler_forwards_the_channel_tag(tmp_db, monkeypatch):
    """converter.py is the only process that spawns ffmpeg, so the channel has
    to survive the trip through the job payload to reach the -metadata flag."""
    import converter
    import downloader

    seen = {}

    def fake_normalize(input_path, channel=None, source_key=None):
        seen["input_path"] = input_path
        seen["channel"] = channel
        return Path("/tmp/out.mp4")

    monkeypatch.setattr(downloader, "_normalize_media_for_ios_sync", fake_normalize)
    tmp_db.enqueue_job(
        "normalize", video_id=7,
        payload={"input_path": "/tmp/in.mkv", "channel": "Veritasium"},
    )

    converter.run_job(tmp_db.claim_job())

    assert seen == {"input_path": Path("/tmp/in.mkv"), "channel": "Veritasium"}
    assert tmp_db.get_job(1)["result"] == {"output_path": "/tmp/out.mp4"}


def test_normalize_handler_forwards_the_youtube_id(tmp_db, monkeypatch):
    import converter
    import downloader

    seen = {}

    def fake_normalize(input_path, channel=None, source_key=None):
        seen["channel"] = channel
        seen["source_key"] = source_key
        return Path("/tmp/out.mp4")

    monkeypatch.setattr(downloader, "_normalize_media_for_ios_sync", fake_normalize)
    tmp_db.enqueue_job(
        "normalize", video_id=7,
        payload={"input_path": "/tmp/in.mkv", "source_key": "dQw4w9WgXcQ"},
    )

    converter.run_job(tmp_db.claim_job())

    assert seen == {"channel": None, "source_key": "dQw4w9WgXcQ"}
