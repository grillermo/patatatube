import importlib

import pytest


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    import services
    importlib.reload(services)
    return db, services


def test_apply_classification_accepts_valid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    assert services.apply_classification(vid, "education") is True
    assert db.get_video(vid)["classification"] == "education"


def test_apply_classification_rejects_invalid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    assert services.apply_classification(vid, "bogus") is False
    assert db.get_video(vid)["classification"] == "children"


def test_apply_move_swaps_positions(fresh_db):
    db, services = fresh_db
    first = db.add_video("https://twitter.com/x/status/1")
    second = db.add_video("https://twitter.com/x/status/2")
    # second has the higher position (added later)
    assert services.apply_move(second, "down") is True
    assert db.get_video(first)["position"] > db.get_video(second)["position"]


def test_apply_move_rejects_bad_direction(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    assert services.apply_move(vid, "sideways") is False
