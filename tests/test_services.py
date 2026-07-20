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
    target_classification = next(cls for cls in db.CLASSIFICATIONS if cls != "children")
    vid = db.add_video("https://twitter.com/x/status/1")
    assert services.apply_classification(vid, target_classification) is True
    assert db.get_video(vid)["classification"] == target_classification


def test_apply_classification_rejects_invalid(fresh_db):
    db, services = fresh_db
    vid = db.add_video("https://twitter.com/x/status/1")
    db.set_video_classification(vid, "children")
    assert services.apply_classification(vid, "bogus") is False
    assert db.get_video(vid)["classification"] == "children"


def test_choose_version_invalidates_existing_hls_package(fresh_db, monkeypatch):
    db, services = fresh_db
    video_id, _ = db.upsert_library_video(
        {
            "source_path": "/media/movie-1080p.mkv",
            "title": "Movie",
            "classification": "movies",
            "versions": [
                {"source_path": "/media/movie-1080p.mkv", "label": "1080p"},
                {"source_path": "/media/movie-4k.mkv", "label": "4K"},
            ],
        }
    )
    selected_version = db.get_video_versions(video_id)[1]
    invalidated = []
    import hls

    monkeypatch.setattr(hls, "invalidate", invalidated.append)

    assert services.choose_version(video_id, selected_version["id"]) is True

    assert invalidated == [video_id]
