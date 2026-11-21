"""Canonical video presenter shared by the SSR page and the JSON API."""


def _hls_ready(video: dict) -> bool:
    """Whether an HLS package can be served for this row. Pure check — never
    touches the filesystem, because this runs once per row in the list endpoint."""
    return video.get("status") == "done"


def preview_url_for(video: dict) -> str | None:
    """Where to fetch this row's poster/thumbnail image from.

    YouTube rows carry an external thumbnail URL straight in the column.
    Twitter and file-upload rows have none, so the preview endpoint grabs a
    frame out of the downloaded mp4.
    """
    external = video.get("preview_url")
    if external:
        return external
    if video.get("status") == "done":
        return f"/videos/{video['id']}/preview"
    return None


def serialize_video(video: dict) -> dict:
    data = {
        "id": video["id"],
        "url": video["url"],
        "title": video.get("title"),
        "platform": video.get("platform"),
        "source_key": video.get("source_key"),
        # The YouTube channel, when known. The clients search on it; the same
        # string is also written into the mp4's `artist` tag at download time.
        "channel": video.get("channel"),
        "preview_url": preview_url_for(video),
        "group_id": video.get("group_id"),
        "position": video.get("position"),
        "resume_secs": video.get("resume_secs") or 0,
        "status": video["status"],
        # Announced and never played -- the same rule the group badge counts
        # (db._UNPLAYED_WHERE), so the dots in a group add up to its badge.
        "unwatched": video.get("play_count") == 0 and video["status"] == "done",
        "error_msg": video.get("error_msg"),
        "stream_path": f"/videos/{video['id']}/stream",
    }
    if _hls_ready(video):
        data["hls_path"] = f"/videos/{video['id']}/hls/master.m3u8"
    if video.get("platform") == "upload":
        # `url` temporarily holds the local upload path until the background
        # processor moves it into videos/{id}.mp4 — never expose it.
        data["url"] = ""
    return data
