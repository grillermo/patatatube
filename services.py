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


def classify_and_announce(
    video_id: int, duration_secs: int | None = None, description: str | None = None
) -> None:
    """File a finished download into a group and start counting its plays.

    Called by converter.py once the video's HLS package exists, not by the
    downloader when the mp4 lands: a video the classifier moves should already
    be playable where the badge sends the user, and the group card's "1 new"
    should appear once, on the group the video ends up in, instead of showing
    in the inbox and then jumping.

    Best effort from end to end. The download has already succeeded, so nothing
    here may raise, and the video is announced whatever the classifier decides
    (or fails to) -- a video that stays in the inbox still counts as new.
    """
    try:
        _classify_into_group(video_id, duration_secs, description)
    except Exception as exc:  # noqa: BLE001 - classification is never fatal
        logger.warning("Classifying video %s failed: %s", video_id, exc)
    db.mark_announced(video_id)
    # The caller has no event loop and no HTTP request is involved, so nothing
    # else would invalidate a cached /api/groups holding the old badge count.
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
        set_group(video_id, group["id"])
