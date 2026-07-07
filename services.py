"""Mutation logic shared by the SSR form endpoints and the JSON API."""

import db
from db import CLASSIFICATIONS


def apply_move(video_id: int, direction: str) -> bool:
    return db.move_video(video_id, direction)


def apply_classification(video_id: int, classification: str) -> bool:
    if classification not in CLASSIFICATIONS:
        return False
    db.set_video_classification(video_id, classification)
    return True


def choose_version(video_id: int, version_id: int) -> bool:
    return db.set_chosen_version(video_id, version_id)
