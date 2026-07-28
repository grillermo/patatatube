"""Move a finished download into the Plex-managed library on disk.

Classifying a downloaded video as tv/movies hands it over to Plex: the file
lands in Plex's own directory and the PatataTube row goes away. It comes back
on a later scan_library() as a normal library row.
"""

import os
import re
from pathlib import Path

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
