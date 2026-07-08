import importlib
import json
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

    async def fake_normalize(path):
        return Path(path)

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

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

    async def fake_normalize(path):
        return Path(path)

    monkeypatch.setattr(downloader, "pybalt_download", fake_pybalt)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

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
    ytdlp_format = captured["cmd"][captured["cmd"].index("-f") + 1]
    assert "vcodec^=avc1" in ytdlp_format
    assert "acodec^=mp4a" in ytdlp_format
    assert title == "Title"
    assert path.exists()
    path.unlink()


def test_ios_normalization_reencodes_unsupported_streams(monkeypatch, downloader_env, tmp_path):
    _db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"source")
    commands = []

    def fake_run(cmd, stdout, stderr, text):
        commands.append(cmd)
        if cmd[0] == "ffprobe-test":
            return subprocess.CompletedProcess(
                cmd,
                0,
                stdout=json.dumps(
                    {
                        "streams": [
                            {"codec_type": "video", "codec_name": "av1", "pix_fmt": "yuv420p"},
                            {"codec_type": "audio", "codec_name": "opus", "channels": 2},
                        ]
                    }
                ),
            )

        Path(cmd[-1]).write_bytes(b"ios-mp4")
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFMPEG_BIN", "ffmpeg-test")
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    output_path = downloader._normalize_media_for_ios_sync(source_file)

    try:
        assert output_path.suffix == ".mp4"
        assert output_path.read_bytes() == b"ios-mp4"
        ffmpeg_cmd = commands[1]
        assert ffmpeg_cmd[ffmpeg_cmd.index("-c:v") + 1] == "libx264"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-c:a") + 1] == "aac"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-movflags") + 1] == "+faststart"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-pix_fmt") + 1] == "yuv420p"
    finally:
        output_path.unlink(missing_ok=True)


def test_ios_normalization_remuxes_safe_h264_aac(monkeypatch, downloader_env, tmp_path):
    _db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"source")
    commands = []

    def fake_run(cmd, stdout, stderr, text):
        commands.append(cmd)
        if cmd[0] == "ffprobe-test":
            return subprocess.CompletedProcess(
                cmd,
                0,
                stdout=json.dumps(
                    {
                        "streams": [
                            {"codec_type": "video", "codec_name": "h264", "pix_fmt": "yuv420p"},
                            {"codec_type": "audio", "codec_name": "aac", "channels": 2},
                        ]
                    }
                ),
            )

        Path(cmd[-1]).write_bytes(b"remuxed")
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFMPEG_BIN", "ffmpeg-test")
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    output_path = downloader._normalize_media_for_ios_sync(source_file)

    try:
        ffmpeg_cmd = commands[1]
        assert output_path.read_bytes() == b"remuxed"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-c:v") + 1] == "copy"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-c:a") + 1] == "copy"
        assert ffmpeg_cmd[ffmpeg_cmd.index("-movflags") + 1] == "+faststart"
    finally:
        output_path.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_process_uploaded_video_success(monkeypatch, downloader_env, tmp_path):
    db, downloader, videos_dir = downloader_env
    tmp_upload = tmp_path / "upload123.mp4"
    tmp_upload.write_bytes(b"uploaded-bytes")
    video_id = db.add_video(str(tmp_upload), platform="upload", title="My Video")

    async def fake_normalize(path):
        return Path(path)

    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    await downloader.process_uploaded_video(video_id)

    video = db.get_video(video_id)
    assert video["status"] == "done"
    assert video["filename"] == f"{video_id}.mp4"
    assert (videos_dir / f"{video_id}.mp4").exists()
    assert not tmp_upload.exists()


@pytest.mark.asyncio
async def test_process_uploaded_video_failure_deletes_row_and_tmpfile(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    tmp_upload = tmp_path / "bad.mp4"
    tmp_upload.write_bytes(b"not-a-real-video")
    video_id = db.add_video(str(tmp_upload), platform="upload", title="Bad Video")

    async def fake_normalize(path):
        raise RuntimeError("ffmpeg failed while normalizing video")

    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    await downloader.process_uploaded_video(video_id)

    assert db.get_video(video_id) is None
    assert not tmp_upload.exists()


@pytest.mark.asyncio
async def test_process_uploaded_video_unknown_id_raises(downloader_env):
    _db, downloader, _videos_dir = downloader_env

    with pytest.raises(ValueError):
        await downloader.process_uploaded_video(99999)
