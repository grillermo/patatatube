"""Mutation logic shared by the SSR form endpoints and the JSON API."""

from dataclasses import dataclass

import db
import hls
import promote
from db import CLASSIFICATIONS


@dataclass(frozen=True)
class ClassificationResult:
    """`promoted` means the file moved into Plex and the row is gone."""

    ok: bool
    promoted: bool = False


def apply_classification(video_id: int, classification: str) -> ClassificationResult:
    """Set a classification, or hand a download over to Plex when it is tv/movies.

    Raises promote.PromotionError when the move fails; nothing is written then.
    """
    if classification not in CLASSIFICATIONS:
        return ClassificationResult(ok=False)
    if classification in promote.PROMOTED_CLASSIFICATIONS:
        video = db.get_video(video_id)
        if video and video.get("source") != "library":
            promote.promote_to_plex(video, classification)
            return ClassificationResult(ok=True, promoted=True)
    db.set_video_classification(video_id, classification)
    return ClassificationResult(ok=True)


def choose_version(video_id: int, version_id: int) -> bool:
    chosen = db.set_chosen_version(video_id, version_id)
    if chosen:
        hls.invalidate(video_id)
    return chosen
