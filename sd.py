"""The /sd player: iPad 1-safe renditions plus a backend-held shuffle.

The iPad 1 decodes H.264 only up to 720p30 Main@3.1, and every file in
videos/ is High profile, so /sd plays a separate `{id}.sd.mp4` that the
converter writes (job kind `sd`). Which group plays, what is on screen and what
has played this round live in the single-row `sd_state` table, so the choice
survives restarts and needs no client storage an iOS 5 browser lacks.
See docs/superpowers/specs/2026-09-18-sd-page-design.md.
"""
import logging
import os
import random
from pathlib import Path

import db
from ffmpeg_progress import probe_duration, run_ffmpeg
from paths import VIDEOS_DIR

logger = logging.getLogger(__name__)

# Behind interactive work (0) and iOS Download-all (100).
SD_PRIORITY = 200
# The one-off backfill of the default group goes ahead of routine SD work.
SD_BACKFILL_PRIORITY = 50


def sd_filename(video_id: int) -> str:
    return f"{video_id}.sd.mp4"


def sd_path(video_id: int) -> Path:
    return VIDEOS_DIR / sd_filename(video_id)


FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")


def part_path(video_id: int) -> Path:
    return VIDEOS_DIR / f"{sd_filename(video_id)}.part"


def encode_cmd(src: Path, dst: Path) -> list[str]:
    """Always a re-encode: a copied High-profile stream is exactly what the
    iPad 1 cannot decode. -f mp4 because the .part suffix hides the format."""
    return [
        FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
        "-map", "0:v:0", "-map", "0:a:0?",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-profile:v", "main", "-level", "3.1", "-pix_fmt", "yuv420p",
        "-vf", "scale=w=1280:h=720:force_original_aspect_ratio=decrease:force_divisible_by=2",
        "-r", "30",
        "-maxrate", "2.5M", "-bufsize", "5M",
        "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        "-movflags", "+faststart", "-f", "mp4", str(dst),
    ]


def _source_duration(path: Path) -> float | None:
    # downloader pulls in pybalt; only the converter process pays for it.
    from downloader import _probe_media

    try:
        return probe_duration(_probe_media(path)) or None
    except Exception:  # noqa: BLE001 - progress is optional, the encode is not
        return None


def build_sd(video_id: int, on_progress=None) -> None:
    """Converter handler body. Raises on failure; sd_ready then stays 0."""
    video = db.get_video(video_id)
    if not video or video.get("source") == "library" or video.get("status") != "done":
        raise ValueError(f"video {video_id} is not a finished download")
    if not video.get("filename"):
        raise ValueError(f"video {video_id} has no file")
    src = VIDEOS_DIR / video["filename"]
    if not src.exists():
        raise FileNotFoundError(f"source missing: {src}")

    part = part_path(video_id)
    try:
        run_ffmpeg(
            encode_cmd(src, part),
            duration=_source_duration(src),
            on_progress=on_progress,
        )
        os.replace(part, sd_path(video_id))
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    db.set_sd_ready(video_id, True)


def next_video() -> dict | None:
    """Advance the shuffle: every candidate once per round, then reshuffle.

    No order is stored — each pick is random among candidates not yet played —
    so videos that become ready mid-round join it and removed ones drop out.
    A new round never opens with the video that just ended.
    """
    state = db.get_sd_state()
    group_id = state["group_id"]
    if group_id is None:
        return None
    candidates = db.sd_candidate_ids(group_id)
    if not candidates:
        return None
    current = state["current_id"]
    played = [vid for vid in state["played"] if vid in candidates]
    pool = [vid for vid in candidates if vid not in played and vid != current]
    if not pool:
        played = []
        pool = [vid for vid in candidates if vid != current] or candidates
    pick = random.choice(pool)
    db.save_sd_state(group_id, pick, played + [pick])
    return db.get_video(pick)


def current_video() -> dict | None:
    state = db.get_sd_state()
    current = state["current_id"]
    if (
        state["group_id"] is not None
        and current is not None
        and current in db.sd_candidate_ids(state["group_id"])
    ):
        return db.get_video(current)
    return next_video()


def enqueue_missing(group_id: int, priority: int = SD_PRIORITY) -> tuple[int, int]:
    """Queue an `sd` job for each eligible video without one. Returns
    (queued, already_pending); a pending job keeps its original priority."""
    queued = already = 0
    for video_id in db.sd_pending_ids(group_id):
        if db.enqueue_job("sd", video_id, priority=priority) is None:
            already += 1
        else:
            queued += 1
    return queued, already


def select_group(group_id: int) -> None:
    db.save_sd_state(group_id, None, [])
    enqueue_missing(group_id)


def enqueue_if_selected(video_id: int) -> bool:
    """Queue an SD rendition for a just-finished download in the /sd group.

    Never raises: it runs inside download_video's try, whose except deletes
    the row, and a finished download must not be lost over a queue hiccup.
    """
    try:
        video = db.get_video(video_id)
        group_id = db.get_sd_state()["group_id"]
        if (
            not video
            or group_id is None
            or video.get("group_id") != group_id
            or video.get("source") == "library"
        ):
            return False
        db.enqueue_job("sd", video_id, priority=SD_PRIORITY)
        return True
    except Exception:  # noqa: BLE001
        logger.exception("Could not queue SD rendition for video %s", video_id)
        return False
