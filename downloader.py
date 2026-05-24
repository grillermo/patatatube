import asyncio
import json
import logging
import os
import shutil
import subprocess
import tempfile
from contextlib import suppress
from pathlib import Path

from pybalt import download as pybalt_download

import db

VIDEOS_DIR = Path("videos")
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


async def _download_twitter(video_id: int, url: str) -> str:
    downloaded_path = await pybalt_download(url)
    downloaded_path = Path(downloaded_path)
    return await _store_ios_compatible_video(video_id, downloaded_path)


async def _download_youtube(video_id: int, url: str) -> tuple[str, str | None]:
    downloaded_path, title = await _download_youtube_media(url)
    dest_name = await _store_ios_compatible_video(video_id, downloaded_path)
    return dest_name, title


async def _store_ios_compatible_video(video_id: int, downloaded_path: Path) -> str:
    normalized_path = await _normalize_media_for_ios(downloaded_path)
    dest = VIDEOS_DIR / f"{video_id}.mp4"
    VIDEOS_DIR.mkdir(exist_ok=True)
    shutil.move(str(normalized_path), str(dest))

    if normalized_path != downloaded_path:
        with suppress(FileNotFoundError):
            downloaded_path.unlink()

    return dest.name


async def _normalize_media_for_ios(input_path: Path) -> Path:
    return await asyncio.to_thread(_normalize_media_for_ios_sync, input_path)


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
        "-print_format",
        "json",
        str(input_path),
    ]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"ffprobe not found at {FFPROBE_BIN!r}; install ffmpeg or set FFPROBE_BIN") from exc

    if proc.returncode != 0:
        raise RuntimeError((proc.stdout or "").strip() or "ffprobe failed while inspecting video")

    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise RuntimeError("ffprobe returned invalid JSON") from exc


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
