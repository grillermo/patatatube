import os
import re
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape

from views.serializers import preview_url_for

# filename, CSS device width, CSS device height, pixel ratio, orientation
SPLASH_STARTUP_IMAGES = (
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_portrait.png", 320, 568, 2, "portrait"),
    ("4__iPhone_SE__iPod_touch_5th_generation_and_later_landscape.png", 320, 568, 2, "landscape"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_portrait.png", 375, 667, 2, "portrait"),
    ("iPhone_8__iPhone_7__iPhone_6s__iPhone_6__4.7__iPhone_SE_landscape.png", 375, 667, 2, "landscape"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_portrait.png", 414, 736, 3, "portrait"),
    ("iPhone_8_Plus__iPhone_7_Plus__iPhone_6s_Plus__iPhone_6_Plus_landscape.png", 414, 736, 3, "landscape"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_portrait.png", 375, 812, 3, "portrait"),
    ("iPhone_13_mini__iPhone_12_mini__iPhone_11_Pro__iPhone_XS__iPhone_X_landscape.png", 375, 812, 3, "landscape"),
    ("iPhone_11__iPhone_XR_portrait.png", 414, 896, 2, "portrait"),
    ("iPhone_11__iPhone_XR_landscape.png", 414, 896, 2, "landscape"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_portrait.png", 414, 896, 3, "portrait"),
    ("iPhone_11_Pro_Max__iPhone_XS_Max_landscape.png", 414, 896, 3, "landscape"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_portrait.png", 390, 844, 3, "portrait"),
    ("iPhone_17e__iPhone_16e__iPhone_14__iPhone_13_Pro__iPhone_13__iPhone_12_Pro__iPhone_12_landscape.png", 390, 844, 3, "landscape"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_portrait.png", 428, 926, 3, "portrait"),
    ("iPhone_14_Plus__iPhone_13_Pro_Max__iPhone_12_Pro_Max_landscape.png", 428, 926, 3, "landscape"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_portrait.png", 393, 852, 3, "portrait"),
    ("iPhone_16__iPhone_15_Pro__iPhone_15__iPhone_14_Pro_landscape.png", 393, 852, 3, "landscape"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_portrait.png", 430, 932, 3, "portrait"),
    ("iPhone_16_Plus__iPhone_15_Pro_Max__iPhone_15_Plus__iPhone_14_Pro_Max_landscape.png", 430, 932, 3, "landscape"),
    ("iPhone_Air_landscape.png", 420, 912, 3, "landscape"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_portrait.png", 402, 874, 3, "portrait"),
    ("iPhone_17_Pro__iPhone_17__iPhone_16_Pro_landscape.png", 402, 874, 3, "landscape"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_portrait.png", 440, 956, 3, "portrait"),
    ("iPhone_17_Pro_Max__iPhone_16_Pro_Max_landscape.png", 440, 956, 3, "landscape"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_portrait.png", 768, 1024, 2, "portrait"),
    ("9.7__iPad_Pro__7.9__iPad_mini__9.7__iPad_Air__9.7__iPad_landscape.png", 768, 1024, 2, "landscape"),
    ("10.2__iPad_portrait.png", 810, 1080, 2, "portrait"),
    ("10.2__iPad_landscape.png", 810, 1080, 2, "landscape"),
    ("10.5__iPad_Air_portrait.png", 834, 1112, 2, "portrait"),
    ("10.5__iPad_Air_landscape.png", 834, 1112, 2, "landscape"),
    ("10.9__iPad_Air_portrait.png", 820, 1180, 2, "portrait"),
    ("10.9__iPad_Air_landscape.png", 820, 1180, 2, "landscape"),
    ("8.3__iPad_Mini_portrait.png", 744, 1133, 2, "portrait"),
    ("8.3__iPad_Mini_landscape.png", 744, 1133, 2, "landscape"),
    ("11__iPad_Pro__10.5__iPad_Pro_portrait.png", 834, 1194, 2, "portrait"),
    ("11__iPad_Pro__10.5__iPad_Pro_landscape.png", 834, 1194, 2, "landscape"),
    ("11__iPad_Pro_M4_portrait.png", 834, 1210, 2, "portrait"),
    ("11__iPad_Pro_M4_landscape.png", 834, 1210, 2, "landscape"),
    ("12.9__iPad_Pro_portrait.png", 1024, 1366, 2, "portrait"),
    ("12.9__iPad_Pro_landscape.png", 1024, 1366, 2, "landscape"),
    ("13__iPad_Pro_M4_portrait.png", 1032, 1376, 2, "portrait"),
    ("13__iPad_Pro_M4_landscape.png", 1032, 1376, 2, "landscape"),
    ("iphone-16-pro-max.jpg", 440, 956, 3, "portrait"),
    ("iphone-15-pro-max.jpg", 430, 932, 3, "portrait"),
    ("iphone-15-14-pro.jpg", 393, 852, 3, "portrait"),
    ("iphone-13-12-pro.jpg", 390, 844, 3, "portrait"),
    ("iphone-14-plus.jpg", 428, 926, 3, "portrait"),
    ("iphone-11-pro-max-xs-max.jpg", 414, 896, 3, "portrait"),
    ("iphone-11-xr.jpg", 414, 896, 2, "portrait"),
    ("iphone-8-plus.jpg", 414, 736, 3, "portrait"),
)


def _preview_src(video: dict) -> str | None:
    """Return a poster URL, adding upload token only for local endpoints."""
    url = preview_url_for(video)
    if url and url.startswith("/videos/"):
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}token={os.getenv('UPLOAD_TOKEN', '')}"
    return url


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


def build_videos_page(videos: list[dict], classifications: list[str], current_classification: str | None) -> str:
    template = _env.get_template("videos_page.html")
    return template.render(
        videos=videos,
        classifications=classifications,
        current_classification=current_classification,
        upload_token=os.getenv("UPLOAD_TOKEN", ""),
        splash_images=SPLASH_STARTUP_IMAGES,
    )
