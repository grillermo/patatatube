import asyncio
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

    async def fake_normalize(path, video_id):
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

    async def fake_normalize(path, video_id):
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


def test_probe_media_ignores_ffprobe_warnings_on_stderr(monkeypatch, downloader_env, tmp_path):
    """A warning like "Referenced QT chapter track not found" must not corrupt the JSON."""
    _db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"source")

    seen = {}

    def fake_run(cmd, stdout, stderr, text):
        seen["stderr"] = stderr
        return subprocess.CompletedProcess(
            cmd,
            0,
            stdout=json.dumps({"streams": [{"codec_type": "video", "codec_name": "h264"}]}),
            stderr="[mov,mp4,m4a,3gp,3g2,mj2 @ 0x1] Referenced QT chapter track not found\n",
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    probe = downloader._probe_media(source_file)

    # Merging stderr into stdout puts the warning ahead of the JSON document.
    assert seen["stderr"] is not subprocess.STDOUT
    assert probe["streams"][0]["codec_name"] == "h264"


def test_probe_media_failure_reports_ffprobe_stderr(monkeypatch, downloader_env, tmp_path):
    _db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"source")

    def fake_run(cmd, stdout, stderr, text):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="source.mp4: Invalid data found\n")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    with pytest.raises(RuntimeError, match="Invalid data found"):
        downloader._probe_media(source_file)


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

    async def fake_normalize(path, video_id):
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

    async def fake_normalize(path, video_id):
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


@pytest.mark.asyncio
async def test_normalize_enqueues_and_awaits_the_job(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")
    output = tmp_path / "out.mp4"

    spawned = []
    monkeypatch.setattr(
        downloader, "_normalize_media_for_ios_sync", lambda p: spawned.append(p)
    )

    async def finish_the_job_out_of_band():
        await asyncio.sleep(0)
        job = db.claim_job()
        db.finish_job(job["id"], "done", result={"output_path": str(output)})

    result, _ = await asyncio.gather(
        downloader._normalize_media_for_ios(source, video_id=42),
        finish_the_job_out_of_band(),
    )

    assert result == output
    assert spawned == [], "the web process must not run ffmpeg itself"


@pytest.mark.asyncio
async def test_normalize_raises_when_the_job_fails(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")

    async def fail_the_job():
        await asyncio.sleep(0)
        job = db.claim_job()
        db.finish_job(job["id"], "failed", error_msg="bad codec")

    with pytest.raises(RuntimeError, match="bad codec"):
        await asyncio.gather(
            downloader._normalize_media_for_ios(source, video_id=42),
            fail_the_job(),
        )


@pytest.mark.parametrize(
    "title,expected",
    [
        ("Lo-fi Beats", "lo-fi-beats"),
        ("  Summer 2026 Mix!!  ", "summer-2026-mix"),
        ("Café Música", "caf-m-sica"),
        ("🎵🎵", "playlist"),
        ("", "playlist"),
        ("a" * 80, "a" * 40),
    ],
)
def test_slugify_playlist_title(downloader_env, title, expected):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._slugify_playlist_title(title) == expected


def test_unique_group_name_returns_slug_when_free(downloader_env):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._unique_group_name("lo-fi-beats", "Lo-fi Beats") == (
        "lo-fi-beats",
        "Lo-fi Beats",
    )


def test_unique_group_name_suffixes_past_existing_groups(downloader_env):
    db, downloader, _videos_dir = downloader_env
    db.create_group("lo-fi-beats", "Lo-fi Beats")
    db.create_group("lo-fi-beats-2", "Lo-fi Beats (2)")

    assert downloader._unique_group_name("lo-fi-beats", "Lo-fi Beats") == (
        "lo-fi-beats-3",
        "Lo-fi Beats (3)",
    )


def test_unique_group_name_avoids_plex_kinds(downloader_env):
    _db, downloader, _videos_dir = downloader_env

    assert downloader._unique_group_name("movies", "Movies") == ("movies-2", "Movies (2)")


def _playlist_json():
    return json.dumps(
        {
            "title": "Lo-fi Beats",
            "entries": [
                {"id": "dQw4w9WgXcQ", "title": "First"},
                {"id": "aBcDeFgHiJk", "title": "Second"},
                {"id": None, "title": "[Deleted video]"},
                {"title": "No id at all"},
                {"id": "short", "title": "Bad id"},
            ],
        }
    )


def test_fetch_playlist_metadata_parses_entries(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout=_playlist_json(), stderr="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    title, entries = downloader._fetch_playlist_metadata_sync(
        "https://www.youtube.com/playlist?list=PL123456789"
    )

    assert title == "Lo-fi Beats"
    assert entries == [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]
    assert seen["cmd"][0] == "/opt/homebrew/bin/yt-dlp"
    assert "--flat-playlist" in seen["cmd"]
    assert "-J" in seen["cmd"]
    assert seen["cmd"][-1] == "https://www.youtube.com/playlist?list=PL123456789"


def test_fetch_playlist_metadata_raises_on_ytdlp_failure(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="ERROR: private playlist")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    with pytest.raises(RuntimeError, match="private playlist"):
        downloader._fetch_playlist_metadata_sync("https://www.youtube.com/playlist?list=PL123456789")


def test_fetch_playlist_metadata_raises_on_bad_json(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="not json", stderr="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    with pytest.raises(RuntimeError):
        downloader._fetch_playlist_metadata_sync("https://www.youtube.com/playlist?list=PL123456789")


def test_fetch_playlist_metadata_ignores_stderr_warnings_on_success(monkeypatch, downloader_env):
    """Verify that warnings in stderr don't corrupt JSON parsing on successful (0) exit."""
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(
            cmd, 0, stdout=_playlist_json(), stderr="WARNING: some deprecation notice\n"
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    # This should succeed despite the warning in stderr
    title, entries = downloader._fetch_playlist_metadata_sync(
        "https://www.youtube.com/playlist?list=PL123456789"
    )

    assert title == "Lo-fi Beats"
    assert len(entries) == 2
    assert entries[0]["id"] == "dQw4w9WgXcQ"
