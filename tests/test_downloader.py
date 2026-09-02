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
        return source_file, "Downloaded Title", "Veritasium"

    async def fake_normalize(path, video_id, channel=None, source_key=None):
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

    async def fake_normalize(path, video_id, channel=None, source_key=None):
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

    path, title, _channel = downloader._download_youtube_media_sync(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )

    assert captured["cmd"][:3] == ["/opt/homebrew/bin/yt-dlp", "--cookies-from-browser", "chrome"]
    ytdlp_format = captured["cmd"][captured["cmd"].index("-f") + 1]
    assert "vcodec^=avc1" in ytdlp_format
    assert "acodec^=mp4a" in ytdlp_format
    assert title == "Title"
    assert path.exists()
    path.unlink()


COOKIE_FAILURE_OUTPUT = (
    "WARNING: failed to decrypt cookie (AES-CBC) because UTF-8 decoding failed. "
    "Possibly the key is wrong?\n"
    "ERROR: unable to download video data: HTTP Error 403: Forbidden\n"
)


def test_youtube_download_retries_without_cookies_after_cookie_failure(
    monkeypatch, downloader_env
):
    _db, downloader, _videos_dir = downloader_env
    calls = []

    def fake_run(cmd, stdout, stderr, text):
        calls.append(cmd)
        if len(calls) == 1:
            return subprocess.CompletedProcess(cmd, 1, stdout=COOKIE_FAILURE_OUTPUT)
        outtmpl = Path(cmd[cmd.index("-o") + 1])
        media_path = Path(str(outtmpl).replace("%(id)s", "dQw4w9WgXcQ").replace("%(ext)s", "mp4"))
        media_path.write_bytes(b"video")
        return subprocess.CompletedProcess(
            cmd, 0, stdout=f"TW2WL_FILE:{media_path}\nTW2WL_TITLE:Title\n"
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    path, title, _channel = downloader._download_youtube_media_sync(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )

    assert len(calls) == 2
    assert "--cookies-from-browser" in calls[0]
    assert "--cookies-from-browser" not in calls[1]
    assert title == "Title"
    path.unlink()


def test_youtube_download_does_not_retry_on_unrelated_failure(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env
    calls = []

    def fake_run(cmd, stdout, stderr, text):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 1, stdout="ERROR: Video unavailable\n")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    with pytest.raises(RuntimeError, match="Video unavailable"):
        downloader._download_youtube_media_sync("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    assert len(calls) == 1


def test_playlist_metadata_retries_without_cookies_after_cookie_failure(
    monkeypatch, downloader_env
):
    _db, downloader, _videos_dir = downloader_env
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        if len(calls) == 1:
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=COOKIE_FAILURE_OUTPUT)
        return subprocess.CompletedProcess(cmd, 0, stdout=_playlist_json(), stderr="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
    monkeypatch.setattr(downloader, "YTDLP_BROWSER", "chrome")

    title, entries = downloader._fetch_playlist_metadata_sync(
        "https://www.youtube.com/playlist?list=PL123456789"
    )

    assert len(calls) == 2
    assert "--cookies-from-browser" in calls[0]
    assert "--cookies-from-browser" not in calls[1]
    assert title == "Lo-fi Beats"
    assert len(entries) == 2


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

    async def fake_normalize(path, video_id, channel=None, source_key=None):
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

    async def fake_normalize(path, video_id, channel=None, source_key=None):
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
        downloader,
        "_normalize_media_for_ios_sync",
        lambda p, channel=None: spawned.append(p),
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


@pytest.fixture()
def playlist_env(monkeypatch, downloader_env):
    """downloader_env plus stubbed metadata, downloads and cache flush."""
    db, downloader, videos_dir = downloader_env
    state = {"downloaded": [], "cache_flushes": 0, "entries": [], "title": "Lo-fi Beats"}

    async def fake_metadata(url):
        state["metadata_url"] = url
        return state["title"], state["entries"]

    async def fake_download(video_id):
        state["downloaded"].append(video_id)
        db.update_video(video_id, status="done", filename=f"{video_id}.mp4")

    async def fake_clear():
        state["cache_flushes"] += 1

    monkeypatch.setattr(downloader, "_fetch_playlist_metadata", fake_metadata)
    monkeypatch.setattr(downloader, "download_video", fake_download)
    monkeypatch.setattr(downloader.cache, "clear", fake_clear)
    return db, downloader, state


@pytest.mark.asyncio
async def test_import_playlist_creates_group_and_queues_entries(playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats")
    assert group is not None
    assert group["label"] == "Lo-fi Beats"

    videos = [v for v in db.get_all_videos() if v["group_id"] == group["id"]]
    assert [v["source_key"] for v in videos] == ["dQw4w9WgXcQ", "aBcDeFgHiJk"]
    assert [v["url"] for v in videos] == [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=aBcDeFgHiJk",
    ]
    assert [v["preview_url"] for v in videos] == [
        "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "https://i.ytimg.com/vi/aBcDeFgHiJk/hqdefault.jpg",
    ]
    assert state["downloaded"] == [v["id"] for v in videos]
    assert state["cache_flushes"] >= 1


@pytest.mark.asyncio
async def test_import_playlist_reuses_completed_video(playlist_env):
    db, downloader, state = playlist_env
    existing_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    db.update_video(existing_id, status="done", filename=f"{existing_id}.mp4")
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats")
    assert db.get_video(existing_id)["group_id"] == group["id"]
    assert state["downloaded"] == []
    assert len(db.get_all_videos()) == 1


@pytest.mark.asyncio
async def test_import_playlist_mixed_reuse_and_new_entries_sort_order(playlist_env):
    """Pins today's actual (imperfect) ordering: a reused entry keeps its old
    position instead of being reinserted at its playlist slot, so it sorts
    after the new entries rather than being interleaved among them. See
    downloader.import_playlist's Fix 2 controller ruling — this is documented,
    not "fixed"."""
    db, downloader, state = playlist_env
    existing_id = db.add_video(
        "https://www.youtube.com/watch?v=aBcDeFgHiJk",
        platform="youtube",
        source_key="aBcDeFgHiJk",
    )
    db.update_video(existing_id, status="done", filename=f"{existing_id}.mp4")
    state["entries"] = [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second (reused)"},
        {"id": "zZyYxXwWvUt", "title": "Third"},
    ]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats")
    videos = [v for v in db.get_all_videos() if v["group_id"] == group["id"]]
    # Actual current behavior: the two new entries (First, Third) come out in
    # correct relative playlist order, but the reused entry (Second) sorts
    # after both of them instead of between them, because it kept the
    # position it already had rather than being reassigned one.
    assert [v["source_key"] for v in videos] == [
        "dQw4w9WgXcQ",
        "zZyYxXwWvUt",
        "aBcDeFgHiJk",
    ]


@pytest.mark.asyncio
async def test_import_playlist_creates_no_group_when_empty(playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = []

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert db.get_group_by_name("lo-fi-beats") is None
    assert db.get_all_videos() == []


@pytest.mark.asyncio
async def test_import_playlist_creates_no_group_when_metadata_fails(monkeypatch, playlist_env):
    db, downloader, _state = playlist_env
    groups_before = db.list_groups()

    async def boom(url):
        raise RuntimeError("private playlist")

    monkeypatch.setattr(downloader, "_fetch_playlist_metadata", boom)

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert db.list_groups() == groups_before  # no group created as a side effect
    assert db.get_group_by_name("lo-fi-beats") is None


@pytest.mark.asyncio
async def test_import_playlist_continues_past_a_failing_entry(monkeypatch, playlist_env):
    db, downloader, state = playlist_env
    state["entries"] = [
        {"id": "dQw4w9WgXcQ", "title": "First"},
        {"id": "aBcDeFgHiJk", "title": "Second"},
    ]

    async def flaky_download(video_id):
        if len(state["downloaded"]) == 0:
            state["downloaded"].append(video_id)
            raise RuntimeError("network died")
        state["downloaded"].append(video_id)
        db.update_video(video_id, status="done", filename=f"{video_id}.mp4")

    monkeypatch.setattr(downloader, "download_video", flaky_download)

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    assert len(state["downloaded"]) == 2


@pytest.mark.asyncio
async def test_import_playlist_suffixes_a_taken_group_name(playlist_env):
    db, downloader, state = playlist_env
    db.create_group("lo-fi-beats", "Lo-fi Beats")
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("lo-fi-beats-2")
    assert group is not None
    assert group["label"] == "Lo-fi Beats (2)"


@pytest.mark.asyncio
async def test_import_playlist_falls_back_when_title_is_empty(playlist_env):
    db, downloader, state = playlist_env
    state["title"] = ""
    state["entries"] = [{"id": "dQw4w9WgXcQ", "title": "First"}]

    await downloader.import_playlist("https://www.youtube.com/playlist?list=PL123456789")

    group = db.get_group_by_name("playlist")
    assert group is not None
    assert group["label"] == "Playlist"


# --- YouTube channel capture -------------------------------------------------


def test_youtube_download_captures_the_channel(monkeypatch, downloader_env):
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
            stdout=(
                f"TW2WL_FILE:{media_path}\n"
                "TW2WL_TITLE:Title\n"
                "TW2WL_CHANNEL:Veritasium\n"
            ),
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    path, title, channel = downloader._download_youtube_media_sync(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )

    # `channel` is the display name; `uploader` is the fallback for the rare
    # video that has no channel field, and an empty default keeps the line
    # printed (and therefore parseable) when neither exists.
    assert "after_move:TW2WL_CHANNEL:%(channel,uploader|)s" in captured["cmd"]
    assert title == "Title"
    assert channel == "Veritasium"
    path.unlink()


def test_youtube_download_tolerates_a_missing_channel(monkeypatch, downloader_env):
    _db, downloader, _videos_dir = downloader_env

    def fake_run(cmd, stdout, stderr, text):
        outtmpl = Path(cmd[cmd.index("-o") + 1])
        media_path = Path(str(outtmpl).replace("%(id)s", "dQw4w9WgXcQ").replace("%(ext)s", "mp4"))
        media_path.write_bytes(b"video")
        return subprocess.CompletedProcess(
            cmd, 0, stdout=f"TW2WL_FILE:{media_path}\nTW2WL_TITLE:Title\nTW2WL_CHANNEL:\n"
        )

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    path, _title, channel = downloader._download_youtube_media_sync(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )

    assert channel is None
    path.unlink()


@pytest.mark.asyncio
async def test_download_youtube_persists_the_channel(monkeypatch, downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")

    async def fake_download(url):
        return source_file, "Downloaded Title", "Veritasium"

    async def fake_normalize(path, video_id, channel=None, source_key=None):
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
    assert video["channel"] == "Veritasium"


@pytest.mark.asyncio
async def test_download_youtube_passes_the_channel_to_normalization(
    monkeypatch, downloader_env, tmp_path
):
    """The tag is written by the ffmpeg step, so the channel has to reach it."""
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")
    seen = {}

    async def fake_download(url):
        return source_file, "Downloaded Title", "Veritasium"

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        seen["channel"] = channel
        return Path(path)

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ", platform="youtube", source_key="x"
    )
    await downloader.download_video(video_id)

    assert seen["channel"] == "Veritasium"


def test_ios_normalization_tags_the_channel_as_artist(monkeypatch, downloader_env, tmp_path):
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
        Path(cmd[-1]).write_bytes(b"tagged")
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFMPEG_BIN", "ffmpeg-test")
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    output_path = downloader._normalize_media_for_ios_sync(source_file, channel="Veritasium")

    try:
        ffmpeg_cmd = commands[1]
        assert ffmpeg_cmd[ffmpeg_cmd.index("-metadata") + 1] == "artist=Veritasium"
    finally:
        output_path.unlink(missing_ok=True)


def test_ios_normalization_writes_no_metadata_without_a_channel(
    monkeypatch, downloader_env, tmp_path
):
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
                    {"streams": [{"codec_type": "video", "codec_name": "h264", "pix_fmt": "yuv420p"}]}
                ),
            )
        Path(cmd[-1]).write_bytes(b"untagged")
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFMPEG_BIN", "ffmpeg-test")
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    output_path = downloader._normalize_media_for_ios_sync(source_file)

    try:
        assert "-metadata" not in commands[1]
    finally:
        output_path.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_normalize_job_payload_carries_the_channel(downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")
    output = tmp_path / "out.mp4"

    async def finish_the_job_out_of_band():
        await asyncio.sleep(0)
        job = db.claim_job()
        assert job["payload"]["channel"] == "Veritasium"
        db.finish_job(job["id"], "done", result={"output_path": str(output)})

    result, _ = await asyncio.gather(
        downloader._normalize_media_for_ios(source, video_id=42, channel="Veritasium"),
        finish_the_job_out_of_band(),
    )

    assert result == output


# --- Backfilling channels onto pre-existing rows -----------------------------


@pytest.mark.asyncio
async def test_backfill_channels_fills_only_missing_youtube_rows(
    monkeypatch, downloader_env
):
    db, downloader, _videos_dir = downloader_env
    queried = []

    def fake_run(cmd, **kwargs):
        queried.append(cmd[-1])
        return subprocess.CompletedProcess(cmd, 0, stdout="Veritasium\n", stderr="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    missing = db.add_video("https://www.youtube.com/watch?v=aaaaaaaaaaa",
                           platform="youtube", source_key="aaaaaaaaaaa")
    db.update_video(missing, status="done", filename=f"{missing}.mp4")
    already = db.add_video("https://www.youtube.com/watch?v=bbbbbbbbbbb",
                           platform="youtube", source_key="bbbbbbbbbbb")
    db.update_video(already, status="done", filename=f"{already}.mp4", channel="Kurzgesagt")
    tweet = db.add_video("https://twitter.com/user/status/123", platform="twitter")
    db.update_video(tweet, status="done", filename=f"{tweet}.mp4")

    filled = await downloader.backfill_channels()

    assert filled == 1
    assert queried == ["https://www.youtube.com/watch?v=aaaaaaaaaaa"]
    assert db.get_video(missing)["channel"] == "Veritasium"
    assert db.get_video(already)["channel"] == "Kurzgesagt"
    assert db.get_video(tweet)["channel"] is None


@pytest.mark.asyncio
async def test_backfill_channels_survives_an_unavailable_video(monkeypatch, downloader_env):
    """A deleted or private video must not abort the rest of the walk."""
    db, downloader, _videos_dir = downloader_env
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd[-1])
        if cmd[-1].endswith("aaaaaaaaaaa"):
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="ERROR: Video unavailable")
        return subprocess.CompletedProcess(cmd, 0, stdout="Kurzgesagt\n", stderr="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)

    dead = db.add_video("https://www.youtube.com/watch?v=aaaaaaaaaaa",
                        platform="youtube", source_key="aaaaaaaaaaa")
    db.update_video(dead, status="done", filename=f"{dead}.mp4")
    alive = db.add_video("https://www.youtube.com/watch?v=bbbbbbbbbbb",
                         platform="youtube", source_key="bbbbbbbbbbb")
    db.update_video(alive, status="done", filename=f"{alive}.mp4")

    filled = await downloader.backfill_channels()

    assert filled == 1
    assert len(calls) == 2
    assert db.get_video(dead)["channel"] is None
    assert db.get_video(alive)["channel"] == "Kurzgesagt"


# --- YouTube id in the container ---------------------------------------------


def test_ios_normalization_tags_the_youtube_id_as_comment(monkeypatch, downloader_env, tmp_path):
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
                    {"streams": [{"codec_type": "video", "codec_name": "h264", "pix_fmt": "yuv420p"}]}
                ),
            )
        Path(cmd[-1]).write_bytes(b"tagged")
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    monkeypatch.setattr(downloader.subprocess, "run", fake_run)
    monkeypatch.setattr(downloader, "FFMPEG_BIN", "ffmpeg-test")
    monkeypatch.setattr(downloader, "FFPROBE_BIN", "ffprobe-test")

    output_path = downloader._normalize_media_for_ios_sync(
        source_file, channel="Veritasium", source_key="dQw4w9WgXcQ"
    )

    try:
        ffmpeg_cmd = commands[1]
        tags = [
            ffmpeg_cmd[i + 1] for i, arg in enumerate(ffmpeg_cmd) if arg == "-metadata"
        ]
        assert tags == ["artist=Veritasium", "comment=dQw4w9WgXcQ"]
    finally:
        output_path.unlink(missing_ok=True)


@pytest.mark.asyncio
async def test_normalize_job_payload_carries_the_youtube_id(downloader_env, tmp_path):
    db, downloader, _videos_dir = downloader_env
    source = tmp_path / "in.mkv"
    source.write_bytes(b"")
    output = tmp_path / "out.mp4"

    async def finish_the_job_out_of_band():
        await asyncio.sleep(0)
        job = db.claim_job()
        assert job["payload"]["source_key"] == "dQw4w9WgXcQ"
        db.finish_job(job["id"], "done", result={"output_path": str(output)})

    result, _ = await asyncio.gather(
        downloader._normalize_media_for_ios(source, video_id=42, source_key="dQw4w9WgXcQ"),
        finish_the_job_out_of_band(),
    )

    assert result == output


@pytest.mark.asyncio
async def test_download_youtube_passes_the_id_to_normalization(
    monkeypatch, downloader_env, tmp_path
):
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "source.mp4"
    source_file.write_bytes(b"youtube-bytes")
    seen = {}

    async def fake_download(url):
        return source_file, "Downloaded Title", "Veritasium"

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        seen["source_key"] = source_key
        return Path(path)

    monkeypatch.setattr(downloader, "_download_youtube_media", fake_download)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    video_id = db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )
    await downloader.download_video(video_id)

    assert seen["source_key"] == "dQw4w9WgXcQ"


@pytest.mark.asyncio
async def test_twitter_downloads_are_not_tagged_with_a_source_key(
    monkeypatch, downloader_env, tmp_path
):
    """`comment` is the YouTube id specifically; a tweet id is not one."""
    db, downloader, _videos_dir = downloader_env
    source_file = tmp_path / "tweet.mp4"
    source_file.write_bytes(b"tweet-bytes")
    seen = {}

    async def fake_pybalt(url):
        return str(source_file)

    async def fake_normalize(path, video_id, channel=None, source_key=None):
        seen["source_key"] = source_key
        seen["channel"] = channel
        return Path(path)

    monkeypatch.setattr(downloader, "pybalt_download", fake_pybalt)
    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    video_id = db.add_video("https://twitter.com/user/status/123",
                            platform="twitter", source_key="123")
    await downloader.download_video(video_id)

    assert seen == {"source_key": None, "channel": None}
