"""Canonical video presenter shared by the SSR page and the JSON API."""


def _hls_ready(video: dict) -> bool:
    """Whether an HLS package can be served for this row.

    Download rows are ready once status is 'done'; library rows once a version
    has converted. Pure check — never touches the filesystem, because this runs
    once per row in the list endpoint.
    """
    if (video.get("source") or "download") == "library":
        versions = video.get("versions") or []
        return any(v.get("status") == "done" for v in versions) or bool(video.get("converted_path"))
    return video.get("status") == "done"


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
        # Sidecar subtitles only exist for library rows; callers that have
        # discovered them inject `subtitle_tracks`. Download rows are always [].
        "subtitle_tracks": video.get("subtitle_tracks") or [],
    }
    if _hls_ready(video):
        data["hls_path"] = f"/videos/{video['id']}/hls/master.m3u8"
    if video.get("versions") is not None:
        data["chosen_version_id"] = video.get("chosen_version_id")
        data["versions"] = [
            {
                "id": version["id"],
                "label": version.get("label"),
                "status": version["status"],
                "is_chosen": bool(version.get("is_chosen")),
            }
            for version in video.get("versions", [])
        ]
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
    if video.get("platform") == "upload":
        # `url` temporarily holds the local upload path until the background
        # processor moves it into videos/{id}.mp4. Treat it like library paths.
        data["url"] = ""
    return data
