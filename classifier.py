"""Pick a video group for a finished download, using TypeSafe's `jev` model.

One `choice` question over the `groups` table: each group's name is an option
and its description (the label when it has none) says what belongs there. The
inbox is left out — it is where a video sits when nobody knows where it
belongs, so it is the fallback, not a target.

`classify` never raises. A missing key, a network error or an unusable answer
all come back as None and the video simply stays in the inbox.
"""

import logging
import os

import httpx

import db

logger = logging.getLogger(__name__)

API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
TIMEOUT_SECS = 30
DESCRIPTION_MAX_CHARS = 1500

INSTRUCTIONS = (
    "Which group should this video be filed under? The video's length is given; "
    "use it as a signal, since some groups hold long videos and others short clips."
)


def _min_confidence() -> float:
    return float(os.getenv("CLASSIFY_MIN_CONFIDENCE", "0.6"))


def format_duration(secs: int) -> str:
    hours, rest = divmod(int(secs), 3600)
    minutes, seconds = divmod(rest, 60)
    if hours:
        return f"{hours}h {minutes}m" if minutes else f"{hours}h"
    if minutes:
        return f"{minutes}m"
    return f"{seconds}s"


def build_state(
    title: str | None,
    channel: str | None,
    duration_secs: int | None,
    description: str | None,
) -> str:
    """The text the model reads. Fields yt-dlp didn't know are left out."""
    lines = []
    if title:
        lines.append(f"Title: {title}")
    if channel:
        lines.append(f"Channel: {channel}")
    if duration_secs:
        lines.append(f"Duration: {format_duration(duration_secs)}")
    if description:
        # Descriptions are mostly link lists and boilerplate after the first
        # paragraph; the cap keeps the token count bounded.
        lines.append(f"Description: {description[:DESCRIPTION_MAX_CHARS]}")
    return "\n".join(lines)


async def _post(payload: dict) -> dict:
    # trust_env=False is not a preference, it is what keeps the worker alive.
    # With it on, httpx asks urllib for the system proxies, which on macOS is
    # _scproxy.get_proxies() -> SystemConfiguration -> a synchronous XPC round
    # trip to cfprefsd. On the child side of gunicorn's fork that Mach port is
    # invalid, so the call hangs ~30s and then segfaults the whole worker --
    # taking the download's BackgroundTask (classification, the play counter,
    # the HLS job) with it. Same reason plex.py passes it on every call.
    async with httpx.AsyncClient(timeout=TIMEOUT_SECS, trust_env=False) as client:
        resp = await client.post(
            API_URL,
            json=payload,
            headers={"Authorization": f"Bearer {os.environ['JEV_API_KEY']}"},
        )
        resp.raise_for_status()
        return resp.json()


async def classify(
    title: str | None,
    channel: str | None,
    duration_secs: int | None,
    description: str | None,
) -> dict | None:
    """The group row the video belongs in, or None to leave it in the inbox."""
    if not os.getenv("JEV_API_KEY"):
        logger.info("[classify] JEV_API_KEY not set; skipping classification")
        return None

    groups = {g["name"]: g for g in db.list_groups() if g["name"] != db.DEFAULT_UPLOAD_GROUP}
    state = build_state(title, channel, duration_secs, description)
    if not groups or not state:
        return None

    payload = {
        "state": state,
        "model": MODEL,
        "questions": {
            "group": {
                "type": "choice",
                "instructions": INSTRUCTIONS,
                "criteria": {
                    name: g.get("description") or g["label"] for name, g in groups.items()
                },
            }
        },
    }
    try:
        answer = (await _post(payload))["answers"]["group"]
        choice, confidence = answer["choice"], float(answer["confidence"])
    except Exception as exc:
        logger.warning("[classify] %r: request failed: %s", title, exc)
        return None

    # The runner-up is what explains a miss: a low confidence is almost always
    # two groups' descriptions both claiming the video.
    ranked = sorted((answer.get("probabilities") or {}).items(), key=lambda kv: -kv[1])
    spread = ", ".join(f"{name} {p:.2f}" for name, p in ranked if p > 0)
    # Options are keyed by the immutable `name`, not the label the app shows,
    # so print both plus the exact text the model judged each one by.
    criteria = payload["questions"]["group"]["criteria"]
    for name, p in ranked[:2]:
        if name in groups:
            logger.info(
                "[classify]   %s (label %r) %.2f: %r", name, groups[name]["label"], p, criteria[name]
            )
    if choice not in groups:
        logger.warning("[classify] %r: chose %r, which is not a group", title, choice)
        return None
    if confidence < _min_confidence():
        logger.info(
            "[classify] %r: chose %s at %.2f < %.2f, keeping in inbox (%s)",
            title, choice, confidence, _min_confidence(), spread,
        )
        return None
    logger.info("[classify] %r: chose %s at %.2f (%s)", title, choice, confidence, spread)
    return groups[choice]
