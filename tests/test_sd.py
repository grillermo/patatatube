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
                "scale=w=1280:h=720:force_original_aspect_ratio=decrease:force_divisible_by=2",
                "-c:a aac"):
        assert arg in joined
    assert cmd[-1] == str(tmp_path / "out.part")


def test_encode_cmd_scale_filter_caps_both_dimensions(tmp_path):
    """A portrait source (e.g. a YouTube Short) must not leave height
    uncapped -- min(1280,iw) alone only caps width, letting a 1080x1920
    source pass through at 1080x1920, far past what the iPad 1 can decode."""
    import sd
    cmd = sd.encode_cmd(tmp_path / "in.mp4", tmp_path / "out.part")
    assert "-vf" in cmd
    vf = cmd[cmd.index("-vf") + 1]
    assert vf == "scale=w=1280:h=720:force_original_aspect_ratio=decrease:force_divisible_by=2"


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


@pytest.mark.asyncio
async def test_finished_download_calls_the_sd_hook(tmp_db, monkeypatch, tmp_path):
    import downloader
    import sd
    calls = []
    monkeypatch.setattr(sd, "enqueue_if_selected", lambda vid: calls.append(vid) or True)

    async def fake_twitter(video_id, url):
        return f"{video_id}.mp4"

    monkeypatch.setattr(downloader, "_download_twitter", fake_twitter)
    vid = tmp_db.add_video("https://twitter.com/x/status/1", group_id=_children(tmp_db))

    await downloader.download_video(vid)

    assert calls == [vid]
    assert tmp_db.get_video(vid)["status"] == "done"


def _api_client(monkeypatch, tmp_path):
    import importlib
    from fastapi.testclient import TestClient
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    import main
    importlib.reload(main)
    return TestClient(main.app)


def test_api_delete_removes_the_sd_file(tmp_db, monkeypatch, tmp_path):
    import router
    videos = tmp_path / "vids"
    videos.mkdir()
    monkeypatch.setattr(router, "VIDEOS_DIR", videos)
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    (videos / f"{vid}.mp4").write_bytes(b"x")
    (videos / f"{vid}.sd.mp4").write_bytes(b"x")

    with _api_client(monkeypatch, tmp_path) as client:
        resp = client.post(f"/api/video/{vid}/delete",
                           headers={"Authorization": "Bearer test-secret"})

    assert resp.status_code == 200
    assert not (videos / f"{vid}.sd.mp4").exists()


def test_promote_removes_the_sd_file(tmp_db, monkeypatch, tmp_path):
    import promote
    videos = tmp_path / "vids"
    videos.mkdir()
    movies = tmp_path / "movies"
    movies.mkdir()
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(movies))
    monkeypatch.setattr(promote, "_refresh_plex", lambda kind: None)
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    (videos / f"{vid}.mp4").write_bytes(b"x")
    (videos / f"{vid}.sd.mp4").write_bytes(b"x")

    promote.promote_to_plex(tmp_db.get_video(vid), "movies")

    assert not (videos / f"{vid}.sd.mp4").exists()


def test_sd_stream_serves_ranges_when_ready(tmp_db, monkeypatch, tmp_path):
    import router
    videos = tmp_path / "vids"
    videos.mkdir()
    monkeypatch.setattr(router, "VIDEOS_DIR", videos)
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    (videos / f"{vid}.sd.mp4").write_bytes(b"0123456789")

    with _api_client(monkeypatch, tmp_path) as client:
        client.cookies.set("upload_token", "test-secret")
        full = client.get(f"/videos/{vid}/sd.mp4")
        part = client.get(f"/videos/{vid}/sd.mp4", headers={"Range": "bytes=2-4"})

    assert full.status_code == 200 and full.content == b"0123456789"
    assert full.headers["content-type"] == "video/mp4"
    assert part.status_code == 206 and part.content == b"234"


def test_sd_stream_404s_when_not_ready_and_401s_without_auth(tmp_db, monkeypatch, tmp_path):
    import router
    videos = tmp_path / "vids"
    videos.mkdir()
    monkeypatch.setattr(router, "VIDEOS_DIR", videos)
    vid = _done_video(tmp_db, _children(tmp_db))
    (videos / f"{vid}.sd.mp4").write_bytes(b"x")

    with _api_client(monkeypatch, tmp_path) as client:
        assert client.get(f"/videos/{vid}/sd.mp4").status_code == 401
        client.cookies.set("upload_token", "test-secret")
        assert client.get(f"/videos/{vid}/sd.mp4").status_code == 404


def _page_client(monkeypatch, tmp_path, cookie=True):
    client = _api_client(monkeypatch, tmp_path)
    if cookie:
        client.cookies.set("upload_token", "test-secret")
    return client


def test_sd_page_redirects_to_login_without_cookie(tmp_db, monkeypatch, tmp_path):
    with _page_client(monkeypatch, tmp_path, cookie=False) as client:
        resp = client.get("/sd", follow_redirects=False)
    assert resp.status_code == 303
    assert resp.headers["location"] == "/login?next=%2Fsd"


def test_sd_page_plays_a_ready_video(tmp_db, monkeypatch, tmp_path):
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    with _page_client(monkeypatch, tmp_path) as client:
        html = client.get("/sd").text
    assert f'src="/videos/{vid}/sd.mp4"' in html
    assert 'id="player"' in html


def test_sd_page_shows_preparing_progress(tmp_db, monkeypatch, tmp_path):
    gid = _children(tmp_db)
    _done_video(tmp_db, gid)
    _done_video(tmp_db, gid)
    with _page_client(monkeypatch, tmp_path) as client:
        html = client.get("/sd").text
    assert "Preparing 0 of 2" in html
    assert 'http-equiv="refresh"' in html
    assert 'id="player"' not in html


def test_sd_page_empty_group_and_no_group(tmp_db, monkeypatch, tmp_path):
    with _page_client(monkeypatch, tmp_path) as client:
        assert "No videos in this group." in client.get("/sd").text
        tmp_db.save_sd_state(None, None, [])
        html = client.get("/sd").text
    assert "Choose a group" in html
    assert 'id="player"' not in html


def test_sd_page_script_is_es5(tmp_db, monkeypatch, tmp_path):
    _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    with _page_client(monkeypatch, tmp_path) as client:
        html = client.get("/sd").text
    for banned in ("fetch(", "=>", "const ", "let ", "Promise", "`",
                   "URLSearchParams", "display: grid", "display:flex",
                   "display: flex", "aspect-ratio"):
        assert banned not in html, banned


def test_sd_group_post_selects_and_redirects(tmp_db, monkeypatch, tmp_path):
    adults = tmp_db.get_group_by_name("adults")["id"]
    with _page_client(monkeypatch, tmp_path) as client:
        resp = client.post("/sd/group", data={"group_id": adults}, follow_redirects=False)
        missing = client.post("/sd/group", data={"group_id": 9999}, follow_redirects=False)
    assert resp.status_code == 303 and resp.headers["location"] == "/sd"
    assert tmp_db.get_sd_state()["group_id"] == adults
    assert missing.status_code == 404


def test_sd_next_json_html_and_empty(tmp_db, monkeypatch, tmp_path):
    vid = _done_video(tmp_db, _children(tmp_db), sd_ready=True)
    with _page_client(monkeypatch, tmp_path) as client:
        as_json = client.post("/sd/next", headers={"Accept": "application/json"})
        as_form = client.post("/sd/next", follow_redirects=False)
        tmp_db.set_sd_ready(vid, False)
        empty = client.post("/sd/next", headers={"Accept": "application/json"})
    with _page_client(monkeypatch, tmp_path, cookie=False) as anon_client:
        anon = anon_client.post("/sd/next")
    assert as_json.status_code == 200
    assert as_json.json() == {"id": vid, "title": as_json.json()["title"],
                              "src": f"/videos/{vid}/sd.mp4"}
    assert as_form.status_code == 303 and as_form.headers["location"] == "/sd"
    assert empty.status_code == 204
    assert anon.status_code == 401


def test_sd_is_never_cached():
    import middleware
    assert "/sd" in middleware._NEVER_CACHED_PATHS


def test_backfill_queues_the_group_once(tmp_db, capsys):
    import sd_backfill
    gid = _children(tmp_db)
    a = _done_video(tmp_db, gid)
    _done_video(tmp_db, gid, sd_ready=True)

    assert sd_backfill.main(["sd_backfill.py", "children"]) == 0
    job = tmp_db.get_job(1)
    assert (job["kind"], job["video_id"], job["priority"]) == ("sd", a, 50)
    assert "queued 1" in capsys.readouterr().out

    assert sd_backfill.main(["sd_backfill.py", "children"]) == 0
    assert "queued 0, already queued 1" in capsys.readouterr().out


def test_backfill_rejects_unknown_group_and_bad_usage(tmp_db):
    import sd_backfill
    assert sd_backfill.main(["sd_backfill.py", "nope"]) == 1
    assert sd_backfill.main(["sd_backfill.py"]) == 2


def test_backfill_force_requeues_already_ready_rows(tmp_db, capsys):
    import sd_backfill
    gid = _children(tmp_db)
    ready = _done_video(tmp_db, gid, sd_ready=True)

    # Without --force, an already-ready row is not requeued.
    assert sd_backfill.main(["sd_backfill.py", "children"]) == 0
    assert "queued 0, already queued 0" in capsys.readouterr().out
    assert tmp_db.get_video(ready)["sd_ready"] == 1

    # With --force, sd_ready is cleared first and the row is queued.
    assert sd_backfill.main(["sd_backfill.py", "children", "--force"]) == 0
    assert tmp_db.get_video(ready)["sd_ready"] == 0
    job = tmp_db.get_job(1)
    assert (job["kind"], job["video_id"], job["priority"]) == ("sd", ready, 50)
    assert "queued 1" in capsys.readouterr().out
