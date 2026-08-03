"""Mutation logic shared by the SSR form endpoints and the JSON API."""

import db
import hls
# Aliased: this module defines a function called `promote`, which would
# otherwise shadow the import and break every `promote.…` reference below.
import promote as plex_promote


def set_group(video_id: int, group_id: int) -> bool:
    """Put a video in a group. False when the group does not exist.

    This is a pure column write. Handing a download to Plex is `promote()` —
    a different verb with different consequences (the file moves, the row is
    deleted), and it used to be spelled as a value of this same call.
    """
    if db.get_group(group_id) is None:
        return False
    db.set_video_group(video_id, group_id)
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
