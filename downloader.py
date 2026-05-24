import asyncio
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from pybalt import download as pybalt_download

import db

VIDEOS_DIR = Path("videos")
YTDLP_BROWSER = os.getenv("YTDLP_BROWSER", "chrome")
YTDLP_BIN = os.getenv("YTDLP_BIN", "/opt/homebrew/bin/yt-dlp")
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
    dest = VIDEOS_DIR / f"{video_id}{downloaded_path.suffix}"
    shutil.move(str(downloaded_path), str(dest))
    return dest.name


async def _download_youtube(video_id: int, url: str) -> tuple[str, str | None]:
    downloaded_path, title = await _download_youtube_media(url)
    dest = VIDEOS_DIR / f"{video_id}{downloaded_path.suffix}"
    shutil.move(str(downloaded_path), str(dest))
    return dest.name, title


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
            "bestvideo+bestaudio/best",
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
