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
