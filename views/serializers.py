"""Canonical video presenter shared by the SSR page and the JSON API."""


def serialize_video(video: dict) -> dict:
    source = video.get("source") or "download"
    data = {
        "id": video["id"],
        "url": video["url"],
        "title": video.get("title"),
        "platform": video.get("platform"),
        "source_key": video.get("source_key"),
        "preview_url": video.get("preview_url"),
        "classification": video.get("classification") or "children",
        "position": video.get("position"),
        "status": video["status"],
        "error_msg": video.get("error_msg"),
        "stream_path": f"/videos/{video['id']}/stream",
        "source": source,
        "show_title": video.get("show_title"),
        "season": video.get("season"),
        "episode": video.get("episode"),
        "summary": video.get("summary"),
        "show_preview_url": None,
    }
    if source == "library":
        # `url` holds the raw filesystem source_path for library rows (see
        # db.upsert_library_video) — never expose that to API consumers.
        # Redact to "" rather than None: the iOS client's Video.url is a
        # non-optional String, and a null would break JSON decoding of the
        # whole /api/videos response. Playback/display use stream_path and
        # title instead, so an empty url is never read for library rows.
        data["url"] = ""
        data["preview_url"] = f"/videos/{video['id']}/preview"
        if video.get("show_rating_key"):
            data["show_preview_url"] = f"/videos/{video['id']}/preview?kind=show"
    return data
