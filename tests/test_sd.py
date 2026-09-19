import json
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


def _done_video(db, group_id, *, sd_ready=False, source=None):
    vid = db.add_video(f"https://twitter.com/x/status/{id(object())}", group_id=group_id)
    db.update_video(vid, "done", filename=f"{vid}.mp4")
    if sd_ready:
        db.set_sd_ready(vid, True)
    if source:
        with db._conn() as conn:
            conn.execute("UPDATE videos SET source = ? WHERE id = ?", (source, vid))
    return vid


def test_sd_state_seeds_the_children_group(tmp_db):
    children = tmp_db.get_group_by_name("children")
    assert tmp_db.get_sd_state() == {
        "group_id": children["id"], "current_id": None, "played": [],
    }


def test_sd_state_seed_is_null_without_a_children_group(tmp_db):
    with tmp_db._conn() as conn:
        conn.execute("UPDATE groups SET name = 'kids' WHERE name = 'children'")
        conn.execute("DELETE FROM sd_state")
    tmp_db.init_db()
    assert tmp_db.get_sd_state()["group_id"] is None


def test_init_db_never_overwrites_a_chosen_group(tmp_db):
    adults = tmp_db.get_group_by_name("adults")
    tmp_db.save_sd_state(adults["id"], None, [])
    tmp_db.init_db()
    assert tmp_db.get_sd_state()["group_id"] == adults["id"]


def test_save_sd_state_round_trips(tmp_db):
    tmp_db.save_sd_state(3, 7, [7, 2])
    assert tmp_db.get_sd_state() == {"group_id": 3, "current_id": 7, "played": [7, 2]}


def test_candidates_and_pending_split_on_sd_ready(tmp_db):
    gid = tmp_db.get_group_by_name("children")["id"]
    other = tmp_db.get_group_by_name("adults")["id"]
    ready = _done_video(tmp_db, gid, sd_ready=True)
    pending = _done_video(tmp_db, gid)
    _done_video(tmp_db, other, sd_ready=True)                  # other group
    _done_video(tmp_db, gid, sd_ready=True, source="library")  # library row
    queued = tmp_db.add_video("https://twitter.com/x/status/9", group_id=gid)  # not done

    assert tmp_db.sd_candidate_ids(gid) == [ready]
    assert tmp_db.sd_pending_ids(gid) == [pending]
    assert tmp_db.sd_counts(gid) == (2, 1)
    assert queued not in tmp_db.sd_pending_ids(gid)


def test_sd_is_a_job_kind(tmp_db):
    assert tmp_db.enqueue_job("sd", video_id=1, priority=200) is not None
    assert tmp_db.enqueue_job("sd", video_id=1, priority=200) is None


def _children(db):
    return db.get_group_by_name("children")["id"]


def test_next_video_plays_every_candidate_once_per_round(tmp_db):
    import sd
    gid = _children(tmp_db)
    ids = {_done_video(tmp_db, gid, sd_ready=True) for _ in range(5)}

    first_round = [sd.next_video()["id"] for _ in range(5)]
    assert set(first_round) == ids

    second_round_opener = sd.next_video()["id"]
    assert second_round_opener != first_round[-1]
    assert tmp_db.get_sd_state()["played"] == [second_round_opener]


def test_next_video_repeats_the_only_candidate(tmp_db):
    import sd
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    assert [sd.next_video()["id"] for _ in range(3)] == [vid, vid, vid]


def test_next_video_is_none_without_candidates(tmp_db):
    import sd
    _done_video(tmp_db, _children(tmp_db))  # not sd_ready
    assert sd.next_video() is None


def test_next_video_is_none_without_a_group(tmp_db):
    import sd
    tmp_db.save_sd_state(None, None, [])
    assert sd.next_video() is None


def test_a_newly_ready_video_joins_the_current_round(tmp_db):
    import sd
    gid = _children(tmp_db)
    a = _done_video(tmp_db, gid, sd_ready=True)
    b = _done_video(tmp_db, gid, sd_ready=True)
    first = sd.next_video()["id"]
    late = _done_video(tmp_db, gid, sd_ready=True)
    rest = {sd.next_video()["id"], sd.next_video()["id"]}
    assert {first} | rest == {a, b, late}


def test_removed_videos_are_never_picked(tmp_db):
    import sd
    gid = _children(tmp_db)
    keep = _done_video(tmp_db, gid, sd_ready=True)
    gone = _done_video(tmp_db, gid, sd_ready=True)
    tmp_db.delete_video(gone)
    assert {sd.next_video()["id"] for _ in range(4)} == {keep}


def test_current_video_keeps_a_valid_current_and_replaces_a_stale_one(tmp_db):
    import sd
    gid = _children(tmp_db)
    a = _done_video(tmp_db, gid, sd_ready=True)
    tmp_db.save_sd_state(gid, a, [a])
    assert sd.current_video()["id"] == a

    tmp_db.save_sd_state(gid, 999, [999])
    assert sd.current_video()["id"] == a


def test_select_group_resets_state_and_queues_pending(tmp_db):
    import sd
    adults = tmp_db.get_group_by_name("adults")["id"]
    pending = _done_video(tmp_db, adults)
    _done_video(tmp_db, adults, sd_ready=True)
    tmp_db.save_sd_state(_children(tmp_db), 5, [5])

    sd.select_group(adults)

    assert tmp_db.get_sd_state() == {"group_id": adults, "current_id": None, "played": []}
    jobs = [tmp_db.get_job(1)]
    assert jobs[0]["kind"] == "sd" and jobs[0]["video_id"] == pending
    assert jobs[0]["priority"] == sd.SD_PRIORITY


def test_enqueue_missing_reports_queued_and_already_pending(tmp_db):
    import sd
    gid = _children(tmp_db)
    _done_video(tmp_db, gid)
    _done_video(tmp_db, gid)
    assert sd.enqueue_missing(gid, priority=50) == (2, 0)
    assert sd.enqueue_missing(gid, priority=50) == (0, 2)


def test_enqueue_if_selected_only_for_the_selected_group(tmp_db):
    import sd
    inside = _done_video(tmp_db, _children(tmp_db))
    outside = _done_video(tmp_db, tmp_db.get_group_by_name("adults")["id"])
    assert sd.enqueue_if_selected(inside) is True
    assert sd.enqueue_if_selected(outside) is False
    assert sd.enqueue_if_selected(424242) is False


def test_enqueue_if_selected_never_raises(tmp_db, monkeypatch):
    import sd
    vid = _done_video(tmp_db, _children(tmp_db))
    monkeypatch.setattr(tmp_db, "enqueue_job", lambda *a, **k: 1 / 0)
    assert sd.enqueue_if_selected(vid) is False


@pytest.fixture()
def videos_dir(monkeypatch, tmp_path):
    import sd
    d = tmp_path / "videos"
    d.mkdir()
    monkeypatch.setattr(sd, "VIDEOS_DIR", d)
    return d


def test_encode_cmd_targets_ipad1_main_31(tmp_path):
    import sd
    cmd = sd.encode_cmd(tmp_path / "in.mp4", tmp_path / "out.part")
    joined = " ".join(cmd)
    for arg in ("-profile:v main", "-level 3.1", "-r 30", "-maxrate 2.5M",
                "-bufsize 5M", "-movflags +faststart", "-f mp4",
                "scale='min(1280,iw)':-2", "-c:a aac"):
        assert arg in joined
    assert cmd[-1] == str(tmp_path / "out.part")


def test_build_sd_writes_atomically_and_marks_ready(tmp_db, videos_dir, monkeypatch):
    import sd
    vid = _done_video(tmp_db, _children(tmp_db))
    (videos_dir / f"{vid}.mp4").write_bytes(b"src")
    seen = {}

    def fake_run(cmd, *, duration=None, on_progress=None):
        seen["duration"] = duration
        part = Path(cmd[-1])
        assert part.name == f"{vid}.sd.mp4.part"
        part.write_bytes(b"sd")

    monkeypatch.setattr(sd, "run_ffmpeg", fake_run)
    monkeypatch.setattr(sd, "_source_duration", lambda path: 12.5)

    sd.build_sd(vid)

    assert (videos_dir / f"{vid}.sd.mp4").read_bytes() == b"sd"
    assert not (videos_dir / f"{vid}.sd.mp4.part").exists()
    assert tmp_db.get_video(vid)["sd_ready"] == 1
    assert seen["duration"] == 12.5


def test_build_sd_failure_leaves_no_file_and_not_ready(tmp_db, videos_dir, monkeypatch):
    import sd
    vid = _done_video(tmp_db, _children(tmp_db))
    (videos_dir / f"{vid}.mp4").write_bytes(b"src")

    def boom(cmd, **kw):
        Path(cmd[-1]).write_bytes(b"half")
        raise RuntimeError("ffmpeg exploded")

    monkeypatch.setattr(sd, "run_ffmpeg", boom)
    monkeypatch.setattr(sd, "_source_duration", lambda path: None)

    with pytest.raises(RuntimeError):
        sd.build_sd(vid)
    assert list(videos_dir.glob("*.sd.mp4*")) == []
    assert tmp_db.get_video(vid)["sd_ready"] == 0


def test_build_sd_rejects_a_missing_source(tmp_db, videos_dir):
    import sd
    vid = _done_video(tmp_db, _children(tmp_db))
    with pytest.raises(FileNotFoundError):
        sd.build_sd(vid)


def test_converter_dispatches_sd_jobs(tmp_db, monkeypatch):
    import converter
    import sd
    built = []
    monkeypatch.setattr(sd, "build_sd", lambda vid, on_progress=None: built.append(vid))
    tmp_db.enqueue_job("sd", video_id=7, priority=200)

    converter.run_job(tmp_db.claim_job())

    assert built == [7]
    assert tmp_db.get_job(1)["status"] == "done"


def test_converter_orphan_cleanup_removes_the_part_file(tmp_db, videos_dir):
    import converter
    part = videos_dir / "7.sd.mp4.part"
    part.write_bytes(b"half")
    converter.cleanup_orphan({"kind": "sd", "video_id": 7})
    assert not part.exists()
