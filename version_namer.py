"""Human-distinguishable labels for a video's alternate versions via a cheap LLM.

Plex hands us several release filenames for the same movie that differ only in
resolution and edition tokens (720p / 1080p / DVDRip, Dual-Lat / Lat, ...). The
raw resolution label (plex._version_label) collides or leaks the whole filename,
so the iOS version Picker is unusable. We ask a cheap OpenAI model to reduce each
filename to just its distinguishing bits, keeping order 1:1 with the input.

Mirrors yosubee's SearchWordService: single chat call, Bearer key from env,
hard-fail on any problem (no silent fallback — callers chose fail-loud).
"""
import json
import os

import httpx

API_URL = "https://api.openai.com/v1/chat/completions"
DEFAULT_MODEL = "gpt-5-nano"

SYSTEM_PROMPT = """\
You are given a numbered list of video filenames that are all different releases \
of the SAME movie. Rewrite each into a short label that a human can tell apart at \
a glance in a dropdown.

Rules:
- Keep ONLY the resolution and the distinguishing attributes (edition, source, and \
language such as "Dual Lat", "Lat", "DVDRip", "BluRay", "Extended").
- Drop the movie title, the year, file extensions, folder paths, and punctuation.
- Normalize separators to single spaces; use readable casing (e.g. "720p Dual Lat").
- Reply with ONLY a JSON array of strings, one per input line, in the same order. \
No prose, no markdown fences.\
"""


class VersionNamerError(RuntimeError):
    pass


def label_versions(filenames: list[str]) -> list[str]:
    """Return one short human-distinguishable label per filename, order preserved.

    Raises VersionNamerError on a missing key, a non-200 response, or any reply
    that isn't a same-length JSON array of non-empty strings.
    """
    if not filenames:
        return []

    api_key = os.getenv("VERSION_NAME_LLM_API_KEY")
    if not api_key:
        raise VersionNamerError("VERSION_NAME_LLM_API_KEY not set")

    model = os.getenv("VERSION_NAME_LLM_MODEL", DEFAULT_MODEL)
    user_content = "\n".join(f"{i + 1}. {name}" for i, name in enumerate(filenames))

    try:
        resp = httpx.post(
            API_URL,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": model,
                "max_completion_tokens": 500,
                "reasoning_effort": "minimal",
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_content},
                ],
            },
            timeout=30,
        )
    except httpx.HTTPError as exc:
        raise VersionNamerError(f"OpenAI request failed: {exc}") from exc

    if resp.status_code != 200:
        raise VersionNamerError(
            f"OpenAI API error ({resp.status_code}): {resp.text}"
        )

    try:
        raw = resp.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError) as exc:
        raise VersionNamerError(f"Unexpected OpenAI response shape: {exc}") from exc

    labels = _parse_labels(raw)
    if len(labels) != len(filenames):
        raise VersionNamerError(
            f"Expected {len(filenames)} labels, got {len(labels)}: {labels!r}"
        )
    return labels


def _parse_labels(raw: str) -> list[str]:
    text = raw.strip()
    # Tolerate a ```json fence if the model adds one despite instructions.
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
        text = text.strip()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise VersionNamerError(f"OpenAI reply was not JSON: {raw!r}") from exc
    if not isinstance(parsed, list):
        raise VersionNamerError(f"OpenAI reply was not a JSON array: {raw!r}")
    labels = []
    for item in parsed:
        if not isinstance(item, str) or not item.strip():
            raise VersionNamerError(f"OpenAI reply had a bad entry: {parsed!r}")
        labels.append(item.strip())
    return labels
