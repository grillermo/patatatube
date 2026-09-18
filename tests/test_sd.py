import json

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
