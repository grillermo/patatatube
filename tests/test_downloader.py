import importlib
import subprocess
from pathlib import Path

import pytest


@pytest.fixture()
def downloader_env(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    videos_dir = tmp_path / "videos"
    videos_dir.mkdir()

    import db
    import downloader

    importlib.reload(db)
    importlib.reload(downloader)
    db.init_db()
    monkeypatch.setattr(downloader, "VIDEOS_DIR", videos_dir)
    return db, downloader, videos_dir


@pytest.mark.asyncio
async def test_download_youtube_success_persists_title(monkeypatch, downloader_env, tmp_path):
    db, downloader, videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")

    async def fake_download(url):
        assert url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        return source_file, "Downloaded Title"

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)

    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    await downloader.download_video(video_id)

    video = db.get_video(video_id)
    assert video["status"] == "done"
    assert video["title"] == "Downloaded Title"
    assert video["filename"] == f"{video_id}.mp4"
    assert (videos_dir / f"{video_id}.mp4").read_bytes() == b"youtube-bytes"


@pytest.mark.asyncio
async def test_download_youtube_failure_deletes_video(monkeypatch, downloader_env):
    db, downloader, _videos_dir = downloader_env

    async def fake_download(url):
        raise RuntimeError("yt-dlp failed")

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)

    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    await downloader.download_video(video_id)

    assert db.get_video(video_id) is None


@pytest.mark.asyncio
async def test_download_twitter_uses_pybalt(monkeypatch, downloader_env, tmp_path):
    db, downloader, videos_dir = downloader_env
    source_file = tmp_path / "tweet.mp4"
    source_file.write_bytes(b"tweet-bytes")

    async def fake_pybalt(url):
        assert url == "https://twitter.com/user/status/123"
        return str(source_file)

    monkeypatch.setattr(downloader, "pybalt_download", fake_pybalt)

    video_id = db.add_video("https://twitter.com/user/status/123", platform="twitter")
    await downloader.download_video(video_id)

    video = db.get_video(video_id)
    assert video["status"] == "done"
    assert video["filename"] == f"{video_id}.mp4"
    assert (videos_dir / f"{video_id}.mp4").read_bytes() == b"tweet-bytes"


def test_youtube_download_uses_browser_cookies(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env
    captured = {}

    def fake_run(cmd, stdout, stderr, text):
        captured["cmd"] = cmd
        outtmpl = Path(cmd[cmd.index("-o") + 1])
        media_path = Path(str(outtmpl).replace("%(id)s", "dQw4w9WgXcQ").replace("%(ext)s", "mp4"))
        media_path.write_bytes(b"video")
        return subprocess.CompletedProcess(
            cmd,
            0,
            stdout=f"TW2WL_FILE:{media_path}\nTW2WL_TITLE:Title\n",
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    path, title = downloader._download_youtube_media_sync("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    assert captured["cmd"][:3] == ["/opt/homebrew/bin/yt-dlp", "--cookies-from-browser", "chrome"]
    assert title == "Title"
    assert path.exists()
    path.unlink()
