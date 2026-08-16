import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
from contextlib import suppress
from pathlib import Path

from pybalt import download as pybalt_download

import db
from paths import VIDEOS_DIR
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")
FFPROBE_BIN = os.getenv("FFPROBE_BIN", "ffprobe")
YTDLP_BROWSER = os.getenv("YTDLP_BROWSER", "chrome")
YTDLP_BIN = os.getenv("YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
YTDLP_FORMAT = os.getenv(
    "YTDLP_FORMAT",
    "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[acodec^=mp4a][ext=m4a]/"
    "bestvideo[vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/"
    "best[ext=mp4]/best",
)
logger = logging.getLogger(__name__)


async def download_video(video_id: int):
    video = db.get_video(video_id)
    if not video:
        raise ValueError(f"Unknown video id: {video_id}")

    db.update_video(video_id, status="downloading")
    try:
        if video["platform"] == "youtube":
            dest_name, title = await _download_youtube(video_id, video["url"])
            db.update_video(video_id, status="done", filename=dest_name, title=title)
            return

        if video["platform"] in (None, "twitter"):
            dest_name = await _download_twitter(video_id, video["url"])
            db.update_video(video_id, status="done", filename=dest_name)
            return

        raise ValueError(f"Unsupported platform: {video['platform']}")
    except Exception as exc:
        logger.warning("Download failed; deleting video row %s: %s", video_id, exc)
        db.delete_video(video_id)


async def process_uploaded_video(video_id: int):
    video = db.get_video(video_id)
    if not video:
        raise ValueError(f"Unknown video id: {video_id}")

    db.update_video(video_id, status="downloading")
    tmp_path = Path(video["url"])
    try:
        dest_name = await _store_ios_compatible_video(video_id, tmp_path)
        db.update_video(video_id, status="done", filename=dest_name)
    except Exception as exc:
        logger.warning("Upload processing failed; deleting video row %s: %s", video_id, exc)
        db.delete_video(video_id)
        with suppress(FileNotFoundError):
            tmp_path.unlink()


async def _download_twitter(video_id: int, url: str) -> str:
    downloaded_path = await pybalt_download(url)
    downloaded_path = Path(downloaded_path)
    return await _store_ios_compatible_video(video_id, downloaded_path)


async def _download_youtube(video_id: int, url: str) -> tuple[str, str | None]:
    downloaded_path, title = await _download_youtube_media(url)
    dest_name = await _store_ios_compatible_video(video_id, downloaded_path)
    return dest_name, title


async def _store_ios_compatible_video(video_id: int, downloaded_path: Path) -> str:
    normalized_path = await _normalize_media_for_ios(downloaded_path, video_id)
    dest = VIDEOS_DIR / f"{video_id}.mp4"
    VIDEOS_DIR.mkdir(exist_ok=True)
    shutil.move(str(normalized_path), str(dest))

    if normalized_path != downloaded_path:
        with suppress(FileNotFoundError):
            downloaded_path.unlink()

    return dest.name


NORMALIZE_POLL_SECONDS = 1.0


async def _normalize_media_for_ios(input_path: Path, video_id: int) -> Path:
    """Hand the ffmpeg work to converter.py and wait for it.

    Polling rather than to_thread: this runs as a BackgroundTask on the event
    loop, so waiting costs no thread, and converter.py is the only process
    allowed to spawn ffmpeg.
    """
    job_id = db.enqueue_job("normalize", video_id, payload={"input_path": str(input_path)})
    if job_id is None:
        raise RuntimeError(f"A normalize job for video {video_id} is already pending")

    while True:
        job = db.get_job(job_id)
        if job["status"] == "done":
            return Path((job["result"] or {})["output_path"])
        if job["status"] == "failed":
            raise RuntimeError(job["error_msg"] or "normalization failed")
        await asyncio.sleep(NORMALIZE_POLL_SECONDS)


def _normalize_media_for_ios_sync(input_path: Path) -> Path:
    input_path = Path(input_path)
    probe = _probe_media(input_path)
    video_stream = _first_stream(probe, "video")
    audio_stream = _first_stream(probe, "audio")
    if not video_stream:
        raise RuntimeError(f"No video stream found in {input_path}")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".mp4") as tmpfile:
        output_path = Path(tmpfile.name)

    cmd = [
        FFMPEG_BIN,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-sn",
        "-dn",
        *_video_codec_args(video_stream),
        *_audio_codec_args(audio_stream),
        "-movflags",
        "+faststart",
        str(output_path),
    ]

    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError as exc:
        output_path.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg not found at {FFMPEG_BIN!r}; install ffmpeg or set FFMPEG_BIN") from exc

    if proc.returncode != 0:
        output_path.unlink(missing_ok=True)
        raise RuntimeError((proc.stdout or "").strip() or "ffmpeg failed while normalizing video")

    return output_path


def _probe_media(input_path: Path) -> dict:
    cmd = [
        FFPROBE_BIN,
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-print_format",
        "json",
        str(input_path),
    ]
    try:
        # stderr gets its own pipe: ffprobe still writes warnings there even at
        # "-v error" (e.g. "Referenced QT chapter track not found"), and merging
        # them into stdout prepends them to the JSON document.
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"ffprobe not found at {FFPROBE_BIN!r}; install ffmpeg or set FFPROBE_BIN") from exc

    if proc.returncode != 0:
        raise RuntimeError(
            (proc.stderr or "").strip()
            or (proc.stdout or "").strip()
            or "ffprobe failed while inspecting video"
        )

    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ffprobe returned invalid JSON: {(proc.stdout or '')[:200]!r}") from exc


def _first_stream(probe: dict, stream_type: str) -> dict | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == stream_type:
            return stream
    return None


def _video_codec_args(stream: dict) -> list[str]:
    if stream.get("codec_name") == "h264" and stream.get("pix_fmt") == "yuv420p":
        return ["-c:v", "copy", "-tag:v", "avc1"]

    return [
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-profile:v",
        "high",
        "-tag:v",
        "avc1",
    ]


def _audio_codec_args(stream: dict | None) -> list[str]:
    if not stream:
        return ["-an"]

    channels = int(stream.get("channels") or 2)
    if stream.get("codec_name") == "aac" and channels <= 2:
        return ["-c:a", "copy"]

    return ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]


async def _download_youtube_media(url: str) -> tuple[Path, str | None]:
    return await asyncio.to_thread(_download_youtube_media_sync, url)


def _download_youtube_media_sync(url: str) -> tuple[Path, str | None]:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)
        outtmpl = str(tmpdir_path / "%(id)s.%(ext)s")
        cmd = [
            YTDLP_BIN,
            "--cookies-from-browser",
            YTDLP_BROWSER,
            "-f",
            YTDLP_FORMAT,
            "--merge-output-format",
            "mp4",
            "--no-playlist",
            "-o",
            outtmpl,
            "--print",
            "after_move:TW2WL_FILE:%(filepath)s",
            "--print",
            "after_move:TW2WL_TITLE:%(title)s",
            "--newline",
            url,
        ]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        output = proc.stdout or ""
        if proc.returncode != 0:
            raise RuntimeError(output.strip() or "yt-dlp failed")

        downloaded_path = _parse_ytdlp_path(output)
        title = _parse_ytdlp_title(output)
        if not downloaded_path:
            downloaded_path = _resolve_downloaded_path(tmpdir_path)

        with tempfile.NamedTemporaryFile(delete=False, suffix=downloaded_path.suffix) as tmpfile:
            stable_path = Path(tmpfile.name)
        shutil.copy2(downloaded_path, stable_path)
        return stable_path, title


def _parse_ytdlp_path(output: str) -> Path | None:
    for line in output.splitlines():
        if line.startswith("TW2WL_FILE:"):
            return Path(line.removeprefix("TW2WL_FILE:"))
    return None


def _parse_ytdlp_title(output: str) -> str | None:
    for line in output.splitlines():
        if line.startswith("TW2WL_TITLE:"):
            return line.removeprefix("TW2WL_TITLE:")
    return None


def _resolve_downloaded_path(tmpdir_path: Path) -> Path:
    matches = sorted(path for path in tmpdir_path.iterdir() if path.is_file())
    if matches:
        return matches[0]

    raise FileNotFoundError("yt-dlp did not produce a downloadable file")


PLAYLIST_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


async def _fetch_playlist_metadata(url: str) -> tuple[str, list[dict]]:
    return await asyncio.to_thread(_fetch_playlist_metadata_sync, url)


def _fetch_playlist_metadata_sync(url: str) -> tuple[str, list[dict]]:
    """(title, entries) for a playlist page.

    `--flat-playlist` keeps this to one cheap request: it lists entries without
    resolving each video, which is all the import loop needs — every entry is
    downloaded later through the normal single-video path.
    """
    cmd = [
        YTDLP_BIN,
        "--cookies-from-browser",
        YTDLP_BROWSER,
        "--flat-playlist",
        "-J",
        url,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = proc.stdout or ""
    if proc.returncode != 0:
        raise RuntimeError(output.strip() or "yt-dlp failed")

    try:
        data = json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Could not parse yt-dlp playlist JSON: {exc}") from exc

    title = (data.get("title") or "").strip()
    entries = []
    for entry in data.get("entries") or []:
        video_id = (entry or {}).get("id") or ""
        # Deleted and private entries keep a slot in the list with no usable id.
        if PLAYLIST_VIDEO_ID_RE.fullmatch(video_id):
            entries.append({"id": video_id, "title": entry.get("title")})
    return title, entries


PLAYLIST_SLUG_MAX_LEN = 40
# Guards against a pathological run of pre-existing groups; hitting it means
# something is wrong, not that the user has 200 identically-named playlists.
PLAYLIST_NAME_MAX_ATTEMPTS = 200


def _slugify_playlist_title(title: str) -> str:
    """A `groups.name` candidate. Non-ASCII-alnum runs collapse to a hyphen."""
    slug = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")
    slug = slug[:PLAYLIST_SLUG_MAX_LEN].strip("-")
    return slug or "playlist"


def _unique_group_name(slug: str, label: str) -> tuple[str, str]:
    """A free (name, label) pair. Playlists never reuse an existing group, so
    a clash suffixes instead of returning the incumbent."""
    for attempt in range(1, PLAYLIST_NAME_MAX_ATTEMPTS + 1):
        name = slug if attempt == 1 else f"{slug}-{attempt}"
        candidate_label = label if attempt == 1 else f"{label} ({attempt})"
        if name not in db.PLEX_KINDS and db.get_group_by_name(name) is None:
            return name, candidate_label
    raise RuntimeError(f"Could not find a free group name for {slug!r}")


async def import_playlist(url: str) -> None:
    """Background-task entry point for a playlist upload. Task 5 implements
    the body (list the playlist via yt-dlp, create the group, download each
    video into it); router.py schedules it as soon as it classifies a
    playlist URL, and tests stub it out via monkeypatch until then."""
    raise NotImplementedError
