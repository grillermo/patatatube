import importlib

import pytest


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db

    importlib.reload(db)
    db.init_db()
    return db


def test_set_group_writes_the_column(fresh_db, monkeypatch):
    import services

    importlib.reload(services)
    gid = fresh_db.get_group_by_name("adults")["id"]
    vid = fresh_db.add_video("https://example.com/x", platform="twitter")
    assert services.set_group(vid, gid) is True
    assert fresh_db.get_video(vid)["group_id"] == gid


def test_set_group_enqueues_an_sd_job_for_the_selected_group(fresh_db):
    import services

    importlib.reload(services)
    gid = fresh_db.get_group_by_name("children")["id"]
    fresh_db.save_sd_state(gid, None, [])
    vid = fresh_db.add_video("https://example.com/sd-move", platform="twitter")

    assert services.set_group(vid, gid) is True

    job = fresh_db.get_job(1)
    assert (job["kind"], job["video_id"]) == ("sd", vid)


def test_set_group_rejects_an_unknown_group(fresh_db):
    import services

    importlib.reload(services)
    vid = fresh_db.add_video("https://example.com/y", platform="twitter")
    assert services.set_group(vid, 9999) is False
    assert fresh_db.get_video(vid)["group_id"] is None

