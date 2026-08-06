import pytest


@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


def test_enqueue_returns_id_and_claim_returns_the_job(tmp_db):
    job_id = tmp_db.enqueue_job("convert", video_id=42, version_id=7)
    assert job_id is not None

    job = tmp_db.claim_job()
    assert job["id"] == job_id
    assert job["kind"] == "convert"
    assert job["video_id"] == 42
    assert job["version_id"] == 7
    assert job["status"] == "running"
    assert job["attempts"] == 1


def test_claim_returns_none_when_queue_empty(tmp_db):
    assert tmp_db.claim_job() is None


def test_payload_round_trips_as_a_dict(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1, payload={"input_path": "/tmp/a.mkv"})
    job = tmp_db.claim_job()
    assert job["payload"] == {"input_path": "/tmp/a.mkv"}


def test_empty_payload_round_trips_as_a_dict(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1, payload={})
    job = tmp_db.claim_job()
    assert job["payload"] == {}


def test_priority_beats_insertion_order(tmp_db):
    bulk = tmp_db.enqueue_job("convert", video_id=1, priority=tmp_db.PRIORITY_BULK)
    interactive = tmp_db.enqueue_job("convert", video_id=2, priority=tmp_db.PRIORITY_INTERACTIVE)

    assert tmp_db.claim_job()["id"] == interactive
    assert tmp_db.claim_job()["id"] == bulk


def test_fifo_within_one_priority(tmp_db):
    first = tmp_db.enqueue_job("convert", video_id=1)
    second = tmp_db.enqueue_job("convert", video_id=2)

    assert tmp_db.claim_job()["id"] == first
    assert tmp_db.claim_job()["id"] == second


def test_claim_is_exclusive(tmp_db):
    """The actual concurrency guarantee: one queued row yields exactly one claim."""
    tmp_db.enqueue_job("convert", video_id=1)

    assert tmp_db.claim_job() is not None
    assert tmp_db.claim_job() is None


def test_duplicate_enqueue_is_a_noop_while_queued(tmp_db):
    first = tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is None
    assert tmp_db.claim_job()["id"] == first
    assert tmp_db.claim_job() is None


def test_duplicate_enqueue_is_a_noop_while_running(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    tmp_db.claim_job()
    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is None


def test_enqueue_allowed_again_after_done(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1, version_id=3)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "done")

    assert tmp_db.enqueue_job("convert", video_id=1, version_id=3) is not None


def test_dedup_applies_to_version_less_kinds(tmp_db):
    """version_id defaults to 0, not NULL - NULLs are distinct in a unique index,
    which would silently disable dedup for normalize and hls."""
    assert tmp_db.enqueue_job("normalize", video_id=1) is not None
    assert tmp_db.enqueue_job("normalize", video_id=1) is None


def test_different_kinds_for_one_video_coexist(tmp_db):
    assert tmp_db.enqueue_job("convert", video_id=1) is not None
    assert tmp_db.enqueue_job("hls", video_id=1) is not None


def test_finish_job_records_status_error_and_result(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "done", result={"output_path": "/tmp/out.mp4"})

    stored = tmp_db.get_job(job["id"])
    assert stored["status"] == "done"
    assert stored["result"] == {"output_path": "/tmp/out.mp4"}
    assert stored["finished_at"] is not None


def test_empty_result_round_trips_as_a_dict(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "done", result={})

    assert tmp_db.get_job(job["id"])["result"] == {}


def test_finish_job_records_failure(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.finish_job(job["id"], "failed", error_msg="ffmpeg exploded")

    stored = tmp_db.get_job(job["id"])
    assert stored["status"] == "failed"
    assert stored["error_msg"] == "ffmpeg exploded"


def test_requeue_job_makes_it_claimable_again(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    job = tmp_db.claim_job()
    tmp_db.requeue_job(job["id"])

    again = tmp_db.claim_job()
    assert again["id"] == job["id"]
    assert again["attempts"] == 2


def test_reset_orphan_jobs_requeues_running_rows_and_returns_them(tmp_db):
    tmp_db.enqueue_job("convert", video_id=42, version_id=7)
    claimed = tmp_db.claim_job()

    orphans = tmp_db.reset_orphan_jobs()

    assert [o["id"] for o in orphans] == [claimed["id"]]
    assert orphans[0]["video_id"] == 42
    assert tmp_db.get_job(claimed["id"])["status"] == "queued"


def test_reset_orphan_jobs_leaves_queued_and_done_alone(tmp_db):
    queued = tmp_db.enqueue_job("convert", video_id=1, priority=tmp_db.PRIORITY_BULK)
    tmp_db.enqueue_job("hls", video_id=2)
    done = tmp_db.claim_job()
    tmp_db.finish_job(done["id"], "done")

    assert tmp_db.reset_orphan_jobs() == []
    assert tmp_db.get_job(queued)["status"] == "queued"
    assert tmp_db.get_job(done["id"])["status"] == "done"


def test_exhausted_job_is_never_claimed(tmp_db):
    """A job that kills the runner every time must not be reclaimed forever."""
    tmp_db.enqueue_job("convert", video_id=1)
    for _ in range(tmp_db.MAX_JOB_ATTEMPTS):
        job = tmp_db.claim_job()
        assert job is not None
        tmp_db.requeue_job(job["id"])

    assert tmp_db.claim_job() is None


def test_sweep_marks_exhausted_jobs_failed(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    for _ in range(tmp_db.MAX_JOB_ATTEMPTS):
        job = tmp_db.claim_job()
        tmp_db.requeue_job(job["id"])

    assert tmp_db.sweep_exhausted_jobs() == 1
    assert tmp_db.get_job(job["id"])["status"] == "failed"
    assert "attempts" in tmp_db.get_job(job["id"])["error_msg"]


def test_recover_exhausted_convert_versions_ignores_failure_superseded_by_newer_work(
    tmp_db, monkeypatch, tmp_path
):
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
    old_id = tmp_db.enqueue_job("convert", video_id=video_id, version_id=version["id"])
    tmp_db.claim_job()
    tmp_db.requeue_job(old_id)
    tmp_db.sweep_exhausted_jobs()

    assert tmp_db.enqueue_job(
        "convert", video_id=video_id, version_id=version["id"]
    ) is not None

    assert tmp_db.recover_exhausted_convert_versions() == 0
    assert tmp_db.get_video_version(video_id, version["id"])["status"] == "converting"


def test_recover_exhausted_convert_versions_ignores_legacy_zero_id(
    tmp_db, monkeypatch, tmp_path
):
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
    job_id = tmp_db.enqueue_job("convert", video_id=video_id)
    tmp_db.claim_job()
    tmp_db.requeue_job(job_id)
    tmp_db.sweep_exhausted_jobs()

    assert tmp_db.recover_exhausted_convert_versions() == 0
    assert tmp_db.get_video_version(video_id, version["id"])["status"] == "converting"


def test_queued_job_count_excludes_running_and_finished(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    tmp_db.enqueue_job("convert", video_id=2)
    tmp_db.enqueue_job("convert", video_id=3)
    tmp_db.claim_job()

    assert tmp_db.queued_job_count() == 2


def test_init_db_is_idempotent_with_the_jobs_table(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1)
    tmp_db.init_db()
    assert tmp_db.queued_job_count() == 1


def test_set_job_progress_stores_the_fraction(tmp_db):
    job_id = tmp_db.enqueue_job("convert", video_id=1, version_id=2)
    tmp_db.claim_job()
    tmp_db.set_job_progress(job_id, 0.42)
    assert tmp_db.get_job(job_id)["progress"] == 0.42


def test_claim_job_resets_progress_to_zero(tmp_db):
    job_id = tmp_db.enqueue_job("convert", video_id=1, version_id=2)
    tmp_db.claim_job()
    tmp_db.set_job_progress(job_id, 0.9)
    tmp_db.requeue_job(job_id)
    claimed = tmp_db.claim_job()
    assert claimed["id"] == job_id
    assert claimed["progress"] == 0


def test_active_jobs_splits_running_from_queued(tmp_db):
    running_id = tmp_db.enqueue_job("convert", video_id=1, version_id=1)
    tmp_db.claim_job()
    tmp_db.set_job_progress(running_id, 0.3)
    tmp_db.enqueue_job("convert", video_id=2, version_id=2)

    snapshot = tmp_db.active_jobs()
    assert [job["id"] for job in snapshot["running"]] == [running_id]
    assert snapshot["running"][0]["progress"] == 0.3
    assert [job["video_id"] for job in snapshot["queued"]] == [2]
    assert snapshot["queued"][0]["progress"] is None
    assert snapshot["queued_total"] == 1


def test_active_jobs_excludes_normalize(tmp_db):
    tmp_db.enqueue_job("normalize", video_id=5, version_id=0)
    snapshot = tmp_db.active_jobs()
    assert snapshot["queued"] == []
    assert snapshot["queued_total"] == 0


def test_active_jobs_caps_queued_but_counts_all(tmp_db):
    for video_id in range(1, 26):
        tmp_db.enqueue_job("convert", video_id=video_id, version_id=video_id)
    snapshot = tmp_db.active_jobs(queued_limit=20)
    assert len(snapshot["queued"]) == 20
    assert snapshot["queued_total"] == 25


def test_active_jobs_orders_queued_by_priority_then_id(tmp_db):
    tmp_db.enqueue_job("convert", video_id=1, version_id=1, priority=tmp_db.PRIORITY_BULK)
    tmp_db.enqueue_job("convert", video_id=2, version_id=2, priority=tmp_db.PRIORITY_INTERACTIVE)
    snapshot = tmp_db.active_jobs()
    assert [job["video_id"] for job in snapshot["queued"]] == [2, 1]


def test_active_jobs_carries_the_video_title(tmp_db):
    video_id = tmp_db.add_video("https://example.com/a", platform="youtube", title="Blade Runner")
    tmp_db.enqueue_job("convert", video_id=video_id, version_id=1)
    snapshot = tmp_db.active_jobs()
    assert snapshot["queued"][0]["title"] == "Blade Runner"
