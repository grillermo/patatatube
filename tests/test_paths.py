import importlib
from pathlib import Path

import pytest

import paths


@pytest.fixture(autouse=True)
def _restore_paths_module():
    yield
    import os

    for var in ("MEDIA_ROOT", "VIDEOS_DIR", "HLS_DIR"):
        os.environ.pop(var, None)
    importlib.reload(paths)


def test_defaults_match_repo_relative_paths(monkeypatch):
    monkeypatch.delenv("MEDIA_ROOT", raising=False)
    monkeypatch.delenv("VIDEOS_DIR", raising=False)
    monkeypatch.delenv("HLS_DIR", raising=False)
    importlib.reload(paths)
    assert paths.VIDEOS_DIR == Path("videos")
    assert paths.HLS_DIR == Path("data/hls")


def test_media_root_composes_subdirs(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    monkeypatch.delenv("VIDEOS_DIR", raising=False)
    monkeypatch.delenv("HLS_DIR", raising=False)
    importlib.reload(paths)
    assert paths.VIDEOS_DIR == tmp_path / "videos"
    assert paths.HLS_DIR == tmp_path / "data/hls"


def test_explicit_dirs_override_media_root(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    monkeypatch.setenv("VIDEOS_DIR", "/custom/videos")
    monkeypatch.setenv("HLS_DIR", "/custom/hls")
    importlib.reload(paths)
    assert paths.VIDEOS_DIR == Path("/custom/videos")
    assert paths.HLS_DIR == Path("/custom/hls")


def test_ensure_media_root_noop_when_unset(monkeypatch):
    monkeypatch.delenv("MEDIA_ROOT", raising=False)
    importlib.reload(paths)
    paths.ensure_media_root()  # must not raise


def test_ensure_media_root_raises_for_nonexistent_root(monkeypatch, tmp_path):
    missing = tmp_path / "does-not-exist"
    monkeypatch.setenv("MEDIA_ROOT", str(missing))
    importlib.reload(paths)
    with pytest.raises(RuntimeError):
        paths.ensure_media_root()


def test_ensure_media_root_raises_when_on_boot_volume(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    importlib.reload(paths)
    with pytest.raises(RuntimeError):
        paths.ensure_media_root()
