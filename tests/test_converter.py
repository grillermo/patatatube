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
