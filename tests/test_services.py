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


def test_set_group_rejects_an_unknown_group(fresh_db):
    import services

    importlib.reload(services)
    vid = fresh_db.add_video("https://example.com/y", platform="twitter")
    assert services.set_group(vid, 9999) is False
    assert fresh_db.get_video(vid)["group_id"] is None


def test_promote_rejects_an_unknown_kind(fresh_db):
    import services

    importlib.reload(services)
    vid = fresh_db.add_video("https://example.com/z", platform="twitter")
    assert services.promote(vid, "podcasts") is False


def test_promote_hands_a_download_to_plex(fresh_db, monkeypatch):
    import promote
    import services

    importlib.reload(services)
    calls = []
    monkeypatch.setattr(promote, "promote_to_plex", lambda v, k: calls.append((v["id"], k)))
    vid = fresh_db.add_video("https://example.com/w", platform="twitter")
    assert services.promote(vid, "tv") is True
    assert calls == [(vid, "tv")]


def test_promote_skips_library_rows(fresh_db, monkeypatch):
    import promote
    import services

    importlib.reload(services)
    monkeypatch.setattr(
        promote, "promote_to_plex", lambda v, k: pytest.fail("library rows never move")
    )
    vid = fresh_db.add_video("https://example.com/l", platform="upload")
    with fresh_db._conn() as conn:
        conn.execute("UPDATE videos SET source = 'library' WHERE id = ?", (vid,))
    assert services.promote(vid, "movies") is False


def test_promote_propagates_a_promotion_failure(fresh_db, monkeypatch):
    import promote as plex_promote
    import services

    importlib.reload(services)

    def fail_move(video, kind):
        raise plex_promote.PromotionError("unavailable")

    monkeypatch.setattr(
        plex_promote,
        "promote_to_plex",
        fail_move,
    )
    vid = fresh_db.add_video("https://example.com/f", platform="twitter")

    with pytest.raises(plex_promote.PromotionError, match="unavailable"):
        services.promote(vid, "movies")

    assert fresh_db.get_video(vid)["group_id"] is None


def test_choose_version_invalidates_existing_hls_package(fresh_db, monkeypatch):
    import services

    importlib.reload(services)
    video_id, _ = fresh_db.upsert_library_video(
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
    selected_version = fresh_db.get_video_versions(video_id)[1]
    invalidated = []
    import hls

    monkeypatch.setattr(hls, "invalidate", invalidated.append)

    assert services.choose_version(video_id, selected_version["id"]) is True

    assert invalidated == [video_id]
