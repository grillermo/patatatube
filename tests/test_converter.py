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


def test_convert_failure_resets_video_and_marks_job_failed(tmp_db, monkeypatch, tmp_path):
    import converter
    import library

    source = tmp_path / "movie.mkv"
    source.write_bytes(b"source")
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
    })
    monkeypatch.setattr(library, "probe_source", lambda path: {
        "format": {"format_name": "matroska"},
        "streams": [
            {"codec_type": "video", "codec_name": "hevc", "width": 1920},
            {"codec_type": "audio", "codec_name": "eac3"},
        ],
    })

    def fail_convert(cmd):
        raise RuntimeError("convert exploded")

    monkeypatch.setattr(library, "_run_ffmpeg", fail_convert)
    version_id = tmp_db.get_video_versions(video_id)[0]["id"]
    tmp_db.enqueue_job("convert", video_id=video_id, version_id=version_id)

    converter.run_job(tmp_db.claim_job())

    video = tmp_db.get_video(video_id)
    job = tmp_db.get_job(1)
    assert video["status"] == "unconverted"
    assert video["error_msg"] == "convert exploded"
    assert job["status"] == "failed"
    assert job["error_msg"] == "convert exploded"


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
    monkeypatch.setattr(
        library,
        "temp_target_for",
        lambda video_id, version_id=None: temp if version_id == 7 else None,
    )

    converter.cleanup_orphan({
        "kind": "convert", "video_id": 42, "version_id": 7, "payload": None,
    })

    assert not temp.exists()


def test_cleanup_orphan_invalidates_partial_hls_output(tmp_db, monkeypatch):
    import converter
    import hls

    invalidated = []
    monkeypatch.setattr(hls, "invalidate", invalidated.append)

    converter.cleanup_orphan({"kind": "hls", "video_id": 42, "payload": None})

    assert invalidated == [42]


def test_convert_job_uses_persisted_version_after_selection_changes(
    tmp_db, monkeypatch, tmp_path
):
    import converter
    import library

    source_1080 = tmp_path / "movie-1080.mkv"
    source_4k = tmp_path / "movie-4k.mkv"
    source_1080.write_bytes(b"1080")
    source_4k.write_bytes(b"4k")
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source_1080),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
        "versions": [
            {"source_path": str(source_1080), "label": "1080p"},
            {"source_path": str(source_4k), "label": "4K"},
        ],
    })
    first, chosen = tmp_db.get_video_versions(video_id)
    assert tmp_db.set_chosen_version(video_id, chosen["id"])
    monkeypatch.setattr(library, "probe_source", lambda path: {
        "format": {"format_name": "matroska"},
        "streams": [
            {"codec_type": "video", "codec_name": "hevc", "width": 1920},
            {"codec_type": "audio", "codec_name": "eac3"},
        ],
    })

    def write_output(cmd):
        tmp_path = Path(cmd[-1])
        tmp_path.write_bytes(b"converted")

    monkeypatch.setattr(library, "_run_ffmpeg", write_output)
    tmp_db.enqueue_job("convert", video_id=video_id, version_id=first["id"])

    converter.run_job(tmp_db.claim_job())

    refreshed = {version["id"]: version for version in tmp_db.get_video_versions(video_id)}
    assert refreshed[first["id"]]["status"] == "done"
    assert refreshed[first["id"]]["converted_path"] == str(tmp_path / "movie-1080.mp4")
    assert refreshed[chosen["id"]]["status"] == "unconverted"
    assert tmp_db.get_video(video_id)["chosen_version_id"] == chosen["id"]
    assert tmp_db.get_job(1)["status"] == "done"


def test_convert_job_without_version_id_does_not_touch_chosen_version(
    tmp_db, tmp_path
):
    import converter

    source = tmp_path / "movie.mkv"
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
    })
    version = tmp_db.get_video_versions(video_id)[0]
    tmp_db.set_library_state(video_id, "converting", version_id=version["id"])
    tmp_db.enqueue_job("convert", video_id=video_id)

    converter.run_job(tmp_db.claim_job())

    assert tmp_db.get_job(1)["status"] == "failed"
    assert tmp_db.get_video_version(video_id, version["id"])["status"] == "converting"


def test_cleanup_orphan_uses_persisted_version_after_selection_changes(tmp_db, tmp_path):
    import converter

    source_1080 = tmp_path / "movie-1080.mkv"
    source_4k = tmp_path / "movie-4k.mkv"
    source_1080.write_bytes(b"1080")
    source_4k.write_bytes(b"4k")
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source_1080),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
        "versions": [
            {"source_path": str(source_1080), "label": "1080p"},
            {"source_path": str(source_4k), "label": "4K"},
        ],
    })
    first, chosen = tmp_db.get_video_versions(video_id)
    assert tmp_db.set_chosen_version(video_id, chosen["id"])
    first_temp = tmp_path / ".movie-1080.mp4"
    chosen_temp = tmp_path / ".movie-4k.mp4"
    first_temp.write_bytes(b"first partial")
    chosen_temp.write_bytes(b"chosen partial")

    converter.cleanup_orphan({
        "kind": "convert",
        "video_id": video_id,
        "version_id": first["id"],
        "payload": None,
    })

    assert not first_temp.exists()
    assert chosen_temp.exists()


def test_exhausted_convert_orphan_resets_its_version(tmp_db, monkeypatch, tmp_path):
    import converter

    source_1080 = tmp_path / "movie-1080.mkv"
    source_4k = tmp_path / "movie-4k.mkv"
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source_1080),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
        "versions": [
            {"source_path": str(source_1080), "label": "1080p"},
            {"source_path": str(source_4k), "label": "4K"},
        ],
    })
    versions = tmp_db.get_video_versions(video_id)
    first, exhausted = versions
    tmp_db.set_library_state(video_id, "converting", version_id=first["id"])
    tmp_db.set_library_state(video_id, "converting", version_id=exhausted["id"])
    monkeypatch.setattr(tmp_db, "MAX_JOB_ATTEMPTS", 1)
    tmp_db.enqueue_job("convert", video_id=video_id, version_id=exhausted["id"])
    tmp_db.claim_job()

    converter.recover_orphans()

    refreshed = {version["id"]: version for version in tmp_db.get_video_versions(video_id)}
    job = tmp_db.get_job(1)
    video = tmp_db.get_video(video_id)
    assert refreshed[first["id"]]["status"] == "converting"
    assert refreshed[exhausted["id"]]["status"] == "unconverted"
    assert refreshed[exhausted["id"]]["error_msg"] == "gave up after 1 attempts"
    assert video["chosen_version_id"] == first["id"]
    assert video["status"] == "converting"
    assert video["error_msg"] is None
    assert job["status"] == "failed"


def test_recover_orphans_repairs_exhausted_version_after_interrupted_recovery(
    tmp_db, monkeypatch, tmp_path
):
    import converter

    source = tmp_path / "movie.mkv"
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
    })
    version = tmp_db.get_video_versions(video_id)[0]
    tmp_db.set_library_state(video_id, "converting", version_id=version["id"])
    monkeypatch.setattr(tmp_db, "MAX_JOB_ATTEMPTS", 1)
    job_id = tmp_db.enqueue_job("convert", video_id=video_id, version_id=version["id"])
    tmp_db.claim_job()

    tmp_db.reset_orphan_jobs()
    tmp_db.sweep_exhausted_jobs()
    assert tmp_db.get_job(job_id)["status"] == "failed"
    assert tmp_db.get_video_version(video_id, version["id"])["status"] == "converting"

    converter.recover_orphans()

    recovered = tmp_db.get_video_version(video_id, version["id"])
    assert recovered["status"] == "unconverted"
    assert recovered["error_msg"] == "gave up after 1 attempts"


def test_legacy_exhausted_job_does_not_override_newer_explicit_version_work(
    tmp_db, monkeypatch, tmp_path
):
    import converter

    source = tmp_path / "movie.mkv"
    video_id, _ = tmp_db.upsert_library_video({
        "source_path": str(source),
        "title": "Movie",
        "plex_kind": "movies",
        "summary": None,
        "plex_rating_key": "1",
    })
    version = tmp_db.get_video_versions(video_id)[0]
    monkeypatch.setattr(tmp_db, "MAX_JOB_ATTEMPTS", 1)
    old_id = tmp_db.enqueue_job("convert", video_id=video_id)
    tmp_db.claim_job()
    tmp_db.requeue_job(old_id)
    tmp_db.sweep_exhausted_jobs()
    tmp_db.set_library_state(video_id, "converting", version_id=version["id"])

    newer_id = tmp_db.enqueue_job("convert", video_id=video_id, version_id=version["id"])

    converter.recover_orphans()

    assert tmp_db.get_job(newer_id)["status"] == "queued"
    assert tmp_db.get_video_version(video_id, version["id"])["status"] == "converting"
