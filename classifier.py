"""Pick a video group for a finished download, using SubQ's `subq-snap-preview`
model, falling back to TypeSafe's `jev` when SubQ fails.

One `choice` question over the `groups` table: each group's name is an option
and its description (the label when it has none) says what belongs there. The
inbox is left out — it is where a video sits when nobody knows where it
belongs, so it is the fallback, not a target.

Both providers speak the same `systemone` request and response, so only the
URL, model and key differ. SubQ goes first; any failure there -- an HTTP or
network error, a malformed response, a choice that is not a group -- moves on
to `jev`. A provider whose key is unset is skipped. A low-confidence answer is
not a failure: it is the model saying it doesn't know, so it is not retried.

`classify` never raises. No keys, every provider failing, or a low confidence
all come back as None and the video simply stays in the inbox.
"""

import logging
import os
from typing import NamedTuple

import httpx

import db

logger = logging.getLogger(__name__)



class Provider(NamedTuple):
    name: str
    url: str
    model: str
    key_env: str


PROVIDERS = (
    Provider("subq", "https://api.subq.ai/v1/systemone", "subq-snap-preview", "SUBQ_API_KEY"),
    Provider("jev", "https://api.typesafe.ai/v1/systemone", "jev-latest", "JEV_API_KEY"),
)
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


async def _post(provider: Provider, payload: dict) -> dict:
    # trust_env=False is not a preference, it is what keeps the worker alive.
    # With it on, httpx asks urllib for the system proxies, which on macOS is
    # _scproxy.get_proxies() -> SystemConfiguration -> a synchronous XPC round
    # trip to cfprefsd. On the child side of gunicorn's fork that Mach port is
    # invalid, so the call hangs ~30s and then segfaults the whole worker --
    # taking the download's BackgroundTask (classification, the play counter,
    # the HLS job) with it. Same reason plex.py passes it on every call.
    async with httpx.AsyncClient(timeout=TIMEOUT_SECS, trust_env=False) as client:
        resp = await client.post(
            provider.url,
            json={**payload, "model": provider.model},
            headers={"Authorization": f"Bearer {os.environ[provider.key_env]}"},
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
    providers = [p for p in PROVIDERS if os.getenv(p.key_env)]
    if not providers:
        logger.info("[classify] no classifier API key set; skipping classification")
        return None

    groups = {g["name"]: g for g in db.list_groups() if g["name"] != db.DEFAULT_UPLOAD_GROUP}
    state = build_state(title, channel, duration_secs, description)
    if not groups or not state:
        return None

    payload = {
        "state": state,
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
    for provider in providers:
        try:
            answer = (await _post(provider, payload))["answers"]["group"]
            choice, confidence = answer["choice"], float(answer["confidence"])
        except Exception as exc:
            logger.warning("[classify] %r: %s request failed: %s", title, provider.name, exc)
            continue
        if choice not in groups:
            logger.warning(
                "[classify] %r: %s chose %r, which is not a group", title, provider.name, choice
            )
            continue
        break
    else:
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
    if confidence < _min_confidence():
        logger.info(
            "[classify] %r: %s chose %s at %.2f < %.2f, keeping in inbox (%s)",
            title, provider.name, choice, confidence, _min_confidence(), spread,
        )
        return None
    logger.info(
        "[classify] %r: %s chose %s at %.2f (%s)",
        title, provider.name, choice, confidence, spread,
    )
    return groups[choice]
