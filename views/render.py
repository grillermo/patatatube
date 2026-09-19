import os
import re
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from views.serializers import preview_url_for


def _preview_src(video: dict) -> str | None:
    """Poster URL. Local /videos/* posters authenticate with the login cookie
    (see router._check_token_or_query); external ones need nothing."""
    return preview_url_for(video)


def _display_name(video: dict) -> str:
    has_named_title = video.get("platform") in ("youtube", "upload") or video.get("source") == "library"
    if has_named_title and video.get("title"):
        return video["title"]

    url = video.get("url", "")
    return url[:60] + ("…" if len(url) > 60 else "")


def _download_name(video: dict) -> str:
    raw_name = video.get("title") or f"video_{video['id']}"
    safe_name = re.sub(r'[\\/:*?"<>|]', "_", raw_name).strip()
    return safe_name or f"video_{video['id']}"


_env = Environment(
    loader=FileSystemLoader(str(Path(__file__).with_name("templates"))),
    autoescape=select_autoescape(["html"]),
)
_env.filters["preview_src"] = _preview_src
_env.filters["display_name"] = _display_name
_env.filters["download_name"] = _download_name


_APP_ASSETS = Path(__file__).resolve().parent.parent / "assets" / "app"


def _asset_version(name: str) -> str:
    """Cache-buster for /assets/app/*.

    Those files ship with `Cache-Control: public, max-age=3600`, so without a
    changing query a CSS/JS edit stays invisible in an already-open browser for
    an hour — the page HTML updates, the behaviour behind it does not.
    """
    try:
        return str(int((_APP_ASSETS / name).stat().st_mtime))
    except OSError:
        return "0"


def build_videos_page(
    videos: list[dict],
    groups: list[dict],
    current_group_id: int | None,
    current_plex_kind: str | None,
) -> str:
    template = _env.get_template("videos_page.html")
    return template.render(
        videos=videos,
        groups=groups,
        current_group_id=current_group_id,
        current_plex_kind=current_plex_kind,
        upload_token=os.getenv("UPLOAD_TOKEN", ""),
        css_version=_asset_version("videos.css"),
        js_version=_asset_version("videos.js"),
    )


def build_login_page(next_url: str = "/", error: bool = False) -> str:
    """The token form. Deliberately self-contained: it must render for someone
    who has no credentials, so it links no token-gated asset and embeds its CSS."""
    template = _env.get_template("login.html")
    return template.render(next_url=next_url, error=error)


def build_sd_page(
    groups: list[dict],
    group_id: int | None,
    video: dict | None,
    total: int,
    ready: int,
) -> str:
    """The iPad 1 (iOS 5) player. Self-contained: inline ES5 and CSS only, no
    /assets/app bundle, which leans on fetch/grid the device lacks."""
    template = _env.get_template("sd.html")
    return template.render(
        groups=groups,
        group_id=group_id,
        video=video,
        title=_display_name(video) if video else "",
        total=total,
        ready=ready,
    )
