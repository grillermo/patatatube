"""Mutation logic shared by the SSR form endpoints and the JSON API."""

import asyncio
import logging

import cache
import classifier
import db
import hls
# Aliased: this module defines a function called `promote`, which would
# otherwise shadow the import and break every `promote.…` reference below.
import promote as plex_promote
import sd

logger = logging.getLogger(__name__)


def set_group(video_id: int, group_id: int) -> bool:
    """Put a video in a group. False when the group does not exist.

    This is a pure column write. Handing a download to Plex is `promote()` —
    a different verb with different consequences (the file moves, the row is
    deleted), and it used to be spelled as a value of this same call.
    """
    video = db.get_video(video_id)
    if db.get_group(group_id) is None or not video or video.get("plex_kind") is not None:
        return False
    db.set_video_group(video_id, group_id)
    # Moving a video into the currently-selected /sd group is one of the
    # trigger points that should queue an SD rendition — otherwise it never
    # gets one until someone reselects the group or reruns the backfill.
    sd.enqueue_if_selected(video_id)
    return True


def promote(video_id: int, kind: str) -> bool:
    """Move a downloaded file into Plex. The row is deleted on success.

    False for an unknown kind, a missing video, or a library row (those already
    live in Plex and never move). Raises promote.PromotionError when the move
    itself fails — nothing is written then.
    """
    if kind not in plex_promote.PLEX_KINDS:
        return False
    video = db.get_video(video_id)
    if not video or video.get("source") == "library":
        return False
    plex_promote.promote_to_plex(video, kind)
    return True


def choose_version(video_id: int, version_id: int) -> bool:
    chosen = db.set_chosen_version(video_id, version_id)
    if chosen:
        hls.invalidate(video_id)
    return chosen


def classify_download(
    video_id: int, duration_secs: int | None = None, description: str | None = None
) -> None:
    """File a still-downloading video into a group.

    Called by the downloader as soon as yt-dlp has the metadata, before the
    mp4 is normalized or packaged: showing the video in its group fast matters
    more than the move coinciding with the badge, which still waits for the
    file (`downloader._announce_new_video`).

    Best effort from end to end. Nothing here may raise -- the caller's except
    deletes the row -- and a video nobody could file just stays in the inbox.
    """
    try:
        _classify_into_group(video_id, duration_secs, description)
    except Exception as exc:  # noqa: BLE001 - classification is never fatal
        logger.warning("Classifying video %s failed: %s", video_id, exc)
    # This runs from a BackgroundTask on a worker thread, with no HTTP request
    # involved, so nothing else would invalidate a cached /api/videos?group_id=.
    cache.clear_blocking()


def _classify_into_group(
    video_id: int, duration_secs: int | None, description: str | None
) -> None:
    """Move a still-unsorted video out of the inbox."""
    inbox = db.get_group_by_name(db.DEFAULT_UPLOAD_GROUP)
    video = db.get_video(video_id)
    # A move made by hand while the download ran wins over the classifier.
    if not inbox or not video or video["group_id"] != inbox["id"]:
        return
    group = asyncio.run(
        classifier.classify(video["title"], video["channel"], duration_secs, description)
    )
    if group is not None:
        # Not set_group(): that queues an SD rendition, and there is no mp4 to
        # render yet. download_video queues it once the file exists.
        db.set_video_group(video_id, group["id"])
        logger.info("[classify] video %s moved to %s (group %s)", video_id, group["name"], group["id"])
