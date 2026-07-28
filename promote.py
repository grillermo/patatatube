"""Move a finished download into the Plex-managed library on disk.

Classifying a downloaded video as tv/movies hands it over to Plex: the file
lands in Plex's own directory and the PatataTube row goes away. It comes back
on a later scan_library() as a normal library row.
"""

import logging
import os
import re
import shutil
from pathlib import Path

import db
import hls
import plex

logger = logging.getLogger(__name__)

VIDEOS_DIR = Path("videos")

# Classification -> (env var holding its Plex directory, default path).
_DEST_ENV = {
    "movies": ("LIBRARY_MOVIES_DIR", "/Volumes/Media/media/movies"),
    "tv": ("LIBRARY_TV_DIR", "/Volumes/Media/media/tv"),
}

PROMOTED_CLASSIFICATIONS = frozenset(_DEST_ENV)

# Path separators, Windows/SMB-reserved characters, and control characters.
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


class PromotionError(RuntimeError):
    """Raised when a video cannot be moved into the Plex library."""


def dest_dir(classification: str) -> Path:
    """Plex directory for a classification, read per-call so env changes apply."""
    try:
        env_name, default = _DEST_ENV[classification]
    except KeyError:
        raise PromotionError(f"not a library classification: {classification}") from None
    return Path(os.getenv(env_name, default))


def sanitize_title(title: str | None, video_id: int) -> str:
    """Filename stem from a video title; Plex matches movies on the filename."""
    cleaned = _UNSAFE.sub(" ", title or "")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = cleaned[:150].strip(" .")
    return cleaned or f"video-{video_id}"


def unique_target(directory: Path, stem: str) -> Path:
    """`{stem}.mp4` in directory, suffixed ` (2)`, ` (3)`... past a collision."""
    target = directory / f"{stem}.mp4"
    if not target.exists():
        return target
    for n in range(2, 51):
        target = directory / f"{stem} ({n}).mp4"
        if not target.exists():
            return target
    raise PromotionError(f"no free filename for {stem!r} in {directory}")


def _refresh_plex(classification: str) -> None:
    """Best-effort rescan: the file is already in place, so a failure is not fatal."""
    if not os.getenv("PLEX_TOKEN"):
        return
    try:
        plex.refresh_sections("movie" if classification == "movies" else "show")
    except Exception as exc:  # noqa: BLE001 - never fail an already-completed move
        logger.warning("Plex refresh after promoting to %s failed: %s", classification, exc)


def promote_to_plex(video: dict, classification: str) -> Path:
    """Move a finished download into its Plex directory and drop its row.

    Returns the new path. On any failure nothing changes: the source file stays
    in videos/, the row stays, and no classification is written.
    """
    if video.get("source") == "library":
        raise PromotionError("library videos are managed by Plex already")
    if video.get("status") != "done":
        raise PromotionError(f"video {video['id']} is not downloaded yet")
    filename = video.get("filename")
    if not filename:
        raise PromotionError(f"video {video['id']} has no file")
    source = VIDEOS_DIR / filename
    if not source.exists():
        raise PromotionError(f"file missing: {source}")

    directory = dest_dir(classification)
    if not directory.is_dir():
        raise PromotionError(f"library directory is unavailable: {directory}")

    target = unique_target(directory, sanitize_title(video.get("title"), video["id"]))
    # videos/ lives on the boot volume and the library on /Volumes/Media, so a
    # plain os.rename would fail with EXDEV. Copy to a hidden sibling of the
    # target first: that replace is same-volume and atomic, so Plex never picks
    # up a half-written file, and the dotfile is invisible to its scanner.
    tmp = target.with_name(f".{target.name}.part")
    try:
        shutil.copyfile(source, tmp)
        os.replace(tmp, target)
    except OSError as exc:
        tmp.unlink(missing_ok=True)
        raise PromotionError(f"could not move {source} to {target}: {exc}") from exc

    source.unlink(missing_ok=True)
    hls.invalidate(video["id"])
    db.delete_video(video["id"])
    _refresh_plex(classification)
    return target
