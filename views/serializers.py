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
        data["preview_url"] = f"/videos/{video['id']}/preview"
        if video.get("show_rating_key"):
            data["show_preview_url"] = f"/videos/{video['id']}/preview?kind=show"
    return data
