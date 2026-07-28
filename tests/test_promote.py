from pathlib import Path

import pytest

import promote


def test_dest_dir_defaults_to_the_plex_media_volume(monkeypatch):
    monkeypatch.delenv("LIBRARY_MOVIES_DIR", raising=False)
    monkeypatch.delenv("LIBRARY_TV_DIR", raising=False)
    assert promote.dest_dir("movies") == Path("/Volumes/Media/media/movies")
    assert promote.dest_dir("tv") == Path("/Volumes/Media/media/tv")


def test_dest_dir_reads_env_on_every_call(monkeypatch, tmp_path):
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "films"))
    assert promote.dest_dir("movies") == tmp_path / "films"
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "other"))
    assert promote.dest_dir("movies") == tmp_path / "other"


def test_dest_dir_rejects_a_non_library_classification():
    with pytest.raises(promote.PromotionError):
        promote.dest_dir("children")


def test_promoted_classifications_are_tv_and_movies():
    assert promote.PROMOTED_CLASSIFICATIONS == frozenset({"tv", "movies"})


def test_sanitize_title_strips_path_and_reserved_characters():
    assert promote.sanitize_title('Rick & Morty: S01/E02?', 7) == "Rick & Morty S01 E02"


def test_sanitize_title_falls_back_to_the_video_id():
    assert promote.sanitize_title(None, 7) == "video-7"
    assert promote.sanitize_title("   ...  ", 7) == "video-7"


def test_sanitize_title_caps_length_at_150_characters():
    assert promote.sanitize_title("a" * 200, 7) == "a" * 150


def test_unique_target_uses_the_plain_name_when_free(tmp_path):
    assert promote.unique_target(tmp_path, "Akira") == tmp_path / "Akira.mp4"


def test_unique_target_suffixes_past_a_collision(tmp_path):
    (tmp_path / "Akira.mp4").write_bytes(b"")
    (tmp_path / "Akira (2).mp4").write_bytes(b"")
    assert promote.unique_target(tmp_path, "Akira") == tmp_path / "Akira (3).mp4"


def test_unique_target_gives_up_after_fifty_collisions(tmp_path):
    (tmp_path / "Akira.mp4").write_bytes(b"")
    for n in range(2, 51):
        (tmp_path / f"Akira ({n}).mp4").write_bytes(b"")
    with pytest.raises(promote.PromotionError):
        promote.unique_target(tmp_path, "Akira")


import importlib


@pytest.fixture()
def promote_env(monkeypatch, tmp_path):
    """Fresh db + a videos/ dir and a Plex movies/tv dir, all under tmp_path."""
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()

    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()
    movies_dir = tmp_path / "movies"
    movies_dir.mkdir()
    tv_dir = tmp_path / "tv"
    tv_dir.mkdir()

    importlib.reload(promote)
    monkeypatch.setattr(promote, "VIDEOS_DIR", videos_dir)
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(movies_dir))
    monkeypatch.setenv("LIBRARY_TV_DIR", str(tv_dir))
    # Most tests do not want to talk to Plex. The real function is stashed under
    # _real_refresh_plex so the few tests that do can put it back.
    monkeypatch.setattr(promote, "_real_refresh_plex", promote._refresh_plex, raising=False)
    monkeypatch.setattr(promote, "_refresh_plex", lambda classification: None)
    return db, videos_dir, movies_dir, tv_dir


def _finished_download(db, videos_dir, title="Akira", body=b"video-bytes"):
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title=title)
    (videos_dir / f"{video_id}.mp4").write_bytes(body)
    db.update_video(video_id, "done", filename=f"{video_id}.mp4")
    return video_id


def test_promote_moves_the_file_and_deletes_the_row(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    video_id = _finished_download(db, videos_dir)

    target = promote.promote_to_plex(db.get_video(video_id), "movies")

    assert target == movies_dir / "Akira.mp4"
    assert target.read_bytes() == b"video-bytes"
    assert not (videos_dir / f"{video_id}.mp4").exists()
    assert db.get_video(video_id) is None


def test_promote_leaves_no_temp_file_behind(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")
    assert sorted(p.name for p in movies_dir.iterdir()) == ["Akira.mp4"]


def test_promote_uses_the_tv_directory_for_tv(promote_env):
    db, videos_dir, _, tv_dir = promote_env
    video_id = _finished_download(db, videos_dir, title="Chef Show")
    assert promote.promote_to_plex(db.get_video(video_id), "tv") == tv_dir / "Chef Show.mp4"


def test_promote_invalidates_the_hls_package_before_deleting(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    invalidated = []
    import hls
    monkeypatch.setattr(hls, "invalidate", invalidated.append)
    video_id = _finished_download(db, videos_dir)

    promote.promote_to_plex(db.get_video(video_id), "movies")

    assert invalidated == [video_id]


def test_promote_refuses_a_library_row(promote_env):
    db, _, _, _ = promote_env
    video = {"id": 1, "source": "library", "status": "done", "filename": "1.mp4"}
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(video, "movies")


def test_promote_refuses_a_download_still_in_progress(promote_env):
    db, videos_dir, _, _ = promote_env
    video_id = db.add_video("https://youtu.be/abc", platform="youtube", title="Akira")
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")
    assert db.get_video(video_id) is not None


def test_promote_refuses_when_the_file_is_gone(promote_env):
    db, videos_dir, _, _ = promote_env
    video_id = _finished_download(db, videos_dir)
    (videos_dir / f"{video_id}.mp4").unlink()
    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")
    assert db.get_video(video_id) is not None


def test_promote_refuses_when_the_media_volume_is_not_mounted(promote_env, monkeypatch, tmp_path):
    db, videos_dir, _, _ = promote_env
    monkeypatch.setenv("LIBRARY_MOVIES_DIR", str(tmp_path / "not-mounted"))
    video_id = _finished_download(db, videos_dir)

    with pytest.raises(promote.PromotionError):
        promote.promote_to_plex(db.get_video(video_id), "movies")

    assert (videos_dir / f"{video_id}.mp4").exists()
    assert db.get_video(video_id) is not None


def test_promote_suffixes_a_colliding_name(promote_env):
    db, videos_dir, movies_dir, _ = promote_env
    (movies_dir / "Akira.mp4").write_bytes(b"already here")
    video_id = _finished_download(db, videos_dir)

    target = promote.promote_to_plex(db.get_video(video_id), "movies")

    assert target == movies_dir / "Akira (2).mp4"
    assert (movies_dir / "Akira.mp4").read_bytes() == b"already here"


def test_promote_asks_plex_to_rescan_the_matching_section(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    # The fixture stubbed _refresh_plex out; put the real one back for this test.
    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    refreshed = []
    import plex
    monkeypatch.setattr(plex, "refresh_sections", lambda t: refreshed.append(t) or 1)

    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")

    assert refreshed == ["movie"]


def test_promote_survives_a_plex_refresh_failure(promote_env, monkeypatch):
    db, videos_dir, movies_dir, _ = promote_env
    monkeypatch.setenv("PLEX_TOKEN", "tok")
    import plex

    def boom(section_type):
        raise plex.PlexError("plex is down")

    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    monkeypatch.setattr(plex, "refresh_sections", boom)
    video_id = _finished_download(db, videos_dir)

    assert promote.promote_to_plex(db.get_video(video_id), "movies") == movies_dir / "Akira.mp4"
    assert db.get_video(video_id) is None


def test_promote_skips_the_plex_call_without_a_token(promote_env, monkeypatch):
    db, videos_dir, _, _ = promote_env
    monkeypatch.delenv("PLEX_TOKEN", raising=False)
    import plex

    def boom(section_type):
        raise AssertionError("must not call Plex without a token")

    monkeypatch.setattr(promote, "_refresh_plex", promote._real_refresh_plex)
    monkeypatch.setattr(plex, "refresh_sections", boom)

    promote.promote_to_plex(db.get_video(_finished_download(db, videos_dir)), "movies")
