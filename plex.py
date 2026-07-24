"""Thin client for the local Plex Media Server HTTP API.

Plex JSON responses can contain raw control characters in summaries,
so every parse goes through _parse_json (strict=False), never resp.json().
"""

import json
import os

import httpx


class PlexError(RuntimeError):
    pass


def _base_url() -> str:
    return os.getenv("PLEX_URL", "http://localhost:32400").rstrip("/")


def _token() -> str:
    token = os.getenv("PLEX_TOKEN", "")
    if not token:
        raise PlexError("PLEX_TOKEN is not configured")
    return token


def _parse_json(text: str) -> dict:
    return json.loads(text, strict=False)


def _get_json(path: str, params: dict | None = None) -> dict:
    params = dict(params or {})
    params["X-Plex-Token"] = _token()
    try:
        resp = httpx.get(
            f"{_base_url()}{path}",
            params=params,
            headers={"Accept": "application/json"},
            timeout=30,
            trust_env=False,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise PlexError(f"Plex request failed: {exc}") from exc
    return _parse_json(resp.text)


def _part_file(meta: dict) -> str | None:
    versions = _part_versions(meta)
    if versions:
        return versions[0]["source_path"]
    return None


def _version_label(media: dict, index: int) -> str:
    resolution = str(media.get("videoResolution") or "").lower()
    if resolution in ("4k", "2160"):
        return "4K"
    if resolution.isdigit():
        return f"{resolution}p"
    return media.get("title") or f"Version {index + 1}"


def _part_versions(meta: dict) -> list[dict]:
    versions = []
    for media in meta.get("Media") or []:
        label = _version_label(media, len(versions))
        for part in media.get("Part") or []:
            if part.get("file"):
                versions.append({"source_path": part["file"], "label": label})
                break
    return versions


def _thumb_version(thumb: str | None) -> str | None:
    """The trailing version token in a Plex thumb path (`/library/metadata/45/
    thumb/1712345678` → `1712345678`). Plex bumps it whenever the poster art
    changes, so it doubles as a cache key for the resized preview."""
    if not thumb:
        return None
    token = thumb.rstrip("/").rsplit("/", 1)[-1]
    return token or None


def _movie_item(meta: dict) -> dict | None:
    path = _part_file(meta)
    if not path:
        return None
    return {
        "source_path": path,
        "title": meta.get("title"),
        "classification": "movies",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": meta.get("summary"),
        "plex_rating_key": str(meta["ratingKey"]),
        "show_rating_key": None,
        "preview_version": _thumb_version(meta.get("thumb")),
        "show_preview_version": None,
        "added_at": meta.get("addedAt"),
        "versions": _part_versions(meta),
    }


def _episode_item(meta: dict) -> dict | None:
    path = _part_file(meta)
    if not path:
        return None
    return {
        "source_path": path,
        "title": meta.get("title"),
        "classification": "tv",
        "show_title": meta.get("grandparentTitle"),
        "season": meta.get("parentIndex"),
        "episode": meta.get("index"),
        "summary": meta.get("summary"),
        "plex_rating_key": str(meta["ratingKey"]),
        "show_rating_key": (
            str(meta["grandparentRatingKey"]) if meta.get("grandparentRatingKey") else None
        ),
        "preview_version": _thumb_version(meta.get("thumb")),
        "show_preview_version": _thumb_version(meta.get("grandparentThumb")),
        "added_at": meta.get("addedAt"),
        "versions": _part_versions(meta),
    }


def fetch_library_items() -> list[dict]:
    """All movie and episode items known to Plex, normalized for db.upsert_library_video."""
    sections = _get_json("/library/sections")["MediaContainer"].get("Directory", [])
    items: list[dict] = []
    for section in sections:
        if section.get("type") == "movie":
            metadata = _get_json(f"/library/sections/{section['key']}/all")[
                "MediaContainer"
            ].get("Metadata", [])
            items.extend(filter(None, (_movie_item(m) for m in metadata)))
        elif section.get("type") == "show":
            shows = _get_json(f"/library/sections/{section['key']}/all")[
                "MediaContainer"
            ].get("Metadata", [])
            for show in shows:
                episodes = _get_json(
                    f"/library/metadata/{show['ratingKey']}/allLeaves"
                )["MediaContainer"].get("Metadata", [])
                items.extend(filter(None, (_episode_item(e) for e in episodes)))
    return items


def fetch_thumb(rating_key: str) -> bytes:
    """JPEG bytes of the item's poster/thumb."""
    try:
        resp = httpx.get(
            f"{_base_url()}/library/metadata/{rating_key}/thumb",
            params={"X-Plex-Token": _token()},
            timeout=30,
            follow_redirects=True,
            trust_env=False,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise PlexError(f"Plex thumb fetch failed: {exc}") from exc
    return resp.content
