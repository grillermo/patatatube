# Jinja Templates Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the f-string HTML builder in `views/templates.py` with Jinja2 templates plus external CSS/JS, so Python and HTML/CSS/JS are cleanly separated.

**Architecture:** A new `views/render.py` owns a module-level Jinja `Environment` (autoescape on), registers three data-prep filters, and exposes `build_videos_page(...)` with the same signature the router already calls. HTML lives in `views/templates/*.html` (a page template + a macros file); CSS and JS move to `assets/app/*` served by a new route mirroring the existing vendor-asset route. The migration is a mechanical extraction — output is byte-identical modulo whitespace.

**Tech Stack:** Python 3.13, FastAPI, Jinja2, pytest.

## Global Constraints

- Jinja `Environment` uses `autoescape=select_autoescape(["html"])` — this replaces every manual `html.escape(...)` call. Do not also escape by hand.
- Extracted CSS/JS/inline-template text must have Python-string artifacts resolved: `{{` → `{`, `}}` → `}`, and `\\` → `\` (backslash was doubled inside the Python source string).
- `build_videos_page(videos, classifications, current_classification) -> str` signature is unchanged — the router depends on it.
- `CLASSIFICATIONS` in `db.py` is `["children", "adults", "anabel", "tv", "movies"]`.
- New asset route must keep the traversal guard (`Path(filename).name == filename`) and `include_in_schema=False`, matching `/assets/vendor/{filename}`.

---

### Task 1: Add Jinja2 dependency

**Files:**
- Modify: `requirements.txt`

**Interfaces:**
- Produces: `jinja2` importable in the venv.

- [ ] **Step 1: Add the pin**

Add this line to `requirements.txt` (alphabetical-ish placement near the other libs is fine, e.g. after `httpx==0.27.2`):

```
Jinja2==3.1.4
```

- [ ] **Step 2: Install it**

Run: `python_env/bin/pip install Jinja2==3.1.4`
Expected: "Successfully installed Jinja2-3.1.4 ..." (or "already satisfied").

- [ ] **Step 3: Verify import**

Run: `python_env/bin/python -c "import jinja2; print(jinja2.__version__)"`
Expected: `3.1.4`

- [ ] **Step 4: Commit**

```bash
git add requirements.txt
git commit -m "build: add Jinja2 dependency"
```

---

### Task 2: Extract CSS to assets/app/videos.css

**Files:**
- Create: `assets/app/videos.css`

**Interfaces:**
- Produces: `/assets/app/videos.css` content (served in Task 7).

The CSS is currently the body of the `<style>` block in `views/templates.py`
(lines **217–262**, i.e. everything between `<style>` on line 216 and
`</style>` on line 263).

- [ ] **Step 1: Create the file**

Copy `views/templates.py` lines 217–262 into `assets/app/videos.css`, applying
the un-doubling transform from Global Constraints (`{{`→`{`, `}}`→`}`). The CSS
has no backslashes. The first rule must read:

```css
*{box-sizing:border-box;margin:0;padding:0}
body{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:12px;padding-top:calc(12px + env(safe-area-inset-top));padding-bottom:calc(12px + env(safe-area-inset-bottom));padding-left:calc(12px + env(safe-area-inset-left));padding-right:calc(12px + env(safe-area-inset-right));}
```

…continuing through the last rule `#nprogress .bar{background:#4a9eff}`.

- [ ] **Step 2: Verify no template delimiters leaked**

Run: `grep -nE '\{\{|\}\}' assets/app/videos.css`
Expected: no output (exit 1). Every `{{`/`}}` must be collapsed to single braces.

- [ ] **Step 3: Commit**

```bash
git add assets/app/videos.css
git commit -m "refactor: extract videos page CSS to assets/app/videos.css"
```

---

### Task 3: Extract JS to assets/app/videos.js

**Files:**
- Create: `assets/app/videos.js`

**Interfaces:**
- Consumes: `window.UPLOAD_TOKEN` (set by an inline bootstrap script in Task 5).
- Produces: `/assets/app/videos.js` content (served in Task 7).

Two `<script>` blocks in `views/templates.py` hold page-behavior JS:
- lines **286–499** — preload / preview-cache / fullscreen logic.
- lines **502–541** — upload-form handler.

Both move into `videos.js`, concatenated in that order. The small inline cookie
redirect script (lines 269–278) stays in the template — do NOT move it here.

- [ ] **Step 1: Create the file**

Copy the two JS blocks (lines 286–499, then 502–541) into `assets/app/videos.js`,
applying the un-doubling transform (`{{`→`{`, `}}`→`}`, `\\`→`\`).

Then replace the token line. The original (line 502) reads:

```javascript
var UPLOAD_TOKEN = {upload_token_json};
```

Replace it with:

```javascript
var UPLOAD_TOKEN = window.UPLOAD_TOKEN || "";
```

The file should start with `var activePreloadController = null;` and end with the
upload-form submit handler's closing `});`.

- [ ] **Step 2: Verify no template delimiters or f-string escapes leaked**

Run: `grep -nE '\{\{|\}\}|\\\\|upload_token_json' assets/app/videos.js`
Expected: no output (exit 1). No doubled braces, no `\\` (backslashes must be
single, e.g. `\s`), and no leftover `upload_token_json`.

- [ ] **Step 3: Sanity-check the token wiring**

Run: `grep -n "window.UPLOAD_TOKEN" assets/app/videos.js`
Expected: one match — `var UPLOAD_TOKEN = window.UPLOAD_TOKEN || "";`

- [ ] **Step 4: Commit**

```bash
git add assets/app/videos.js
git commit -m "refactor: extract videos page JS to assets/app/videos.js"
```

---

### Task 4: Create the macros template

**Files:**
- Create: `views/templates/_macros.html`

**Interfaces:**
- Consumes: filters `display_name`, `preview_src`, `download_name` (defined in Task 6); macros receive raw video dicts.
- Produces: macros `splash_links(images)`, `nav(classifications, current)`, `classification_menu(v, classifications, current)`, `card(v, classifications, current, upload_token)`.

- [ ] **Step 1: Write the file**

Create `views/templates/_macros.html` with exactly:

```jinja
{% macro splash_links(images) -%}
<link rel="apple-touch-startup-image" href="/apple-splash-optimized.jpg">
{% for f, w, h, scale, orient in images -%}
<link rel="apple-touch-startup-image" media="(device-width: {{ w }}px) and (device-height: {{ h }}px) and (-webkit-device-pixel-ratio: {{ scale }}) and (orientation: {{ orient }})" href="/assets/splash/{{ f }}">
{% endfor -%}
{%- endmacro %}

{% macro nav(classifications, current) -%}
<nav class="nav">
{%- for cls in classifications -%}
<a href="/?classification={{ cls }}" class="nav-link{{ ' active' if cls == current else '' }}">{{ cls }}</a>
{%- endfor -%}
</nav>
{%- endmacro %}

{% macro classification_menu(v, classifications, current) -%}
<details class="menu">
<summary>&#8942;</summary>
<div class="menu-dropdown">
{%- for cls in classifications -%}
<form method="post" action="/videos/{{ v.id }}/classify">
<input type="hidden" name="current_classification" value="{{ current or '' }}">
<input type="hidden" name="classification" value="{{ cls }}">
<button type="submit" class="menu-btn{{ ' active-cls' if cls == (v.classification or 'children') else '' }}">{{ cls }}</button>
</form>
{%- endfor -%}
</div>
</details>
{%- endmacro %}

{% macro card(v, classifications, current, upload_token) -%}
<div class="card">
{{ classification_menu(v, classifications, current) }}
{% if v.status == "done" -%}
<div class="video-wrap">
<div class="name-overlay">{{ v | display_name }}</div>
<video id="v{{ v.id }}" controls playsinline webkit-playsinline preload="none" onloadedmetadata="this.currentTime=0"{% set p = v | preview_src %}{% if p %} data-preview-src="{{ p }}"{% endif %}>
<source src="/videos/{{ v.id }}/stream?token={{ upload_token }}" type="video/mp4">
</video>
</div>
{%- elif v.status == "error" -%}
<p style="color:#c00;font-size:0.85em">Error: {{ v.error_msg or "unknown" }}</p>
{%- else -%}
<p style="color:#aaa;font-size:0.85em">Video is {{ v.status }}…</p>
{%- endif %}
<div class="move">
{% if v.status == "done" -%}
<a class="download-btn" href="/videos/{{ v.id }}/stream?token={{ upload_token }}" download="{{ v | download_name }}.mp4" aria-label="Download video">&#8681;</a>
{%- endif %}
<form method="post" action="/videos/{{ v.id }}/move">
<input type="hidden" name="direction" value="up">
<input type="hidden" name="classification" value="{{ current or '' }}">
<button type="submit" aria-label="Move up">&#9650;</button>
</form>
<form method="post" action="/videos/{{ v.id }}/move">
<input type="hidden" name="direction" value="down">
<input type="hidden" name="classification" value="{{ current or '' }}">
<button type="submit" aria-label="Move down">&#9660;</button>
</form>
</div>
</div>
{%- endmacro %}
```

Note: `v.id`, `v.classification`, etc. use Jinja attribute access, which falls
back to dict-item access — correct for the plain dicts these macros receive.

- [ ] **Step 2: Commit**

```bash
git add views/templates/_macros.html
git commit -m "feat: add Jinja macros for videos page cards, nav, splash"
```

---

### Task 5: Create the page template

**Files:**
- Create: `views/templates/videos_page.html`

**Interfaces:**
- Consumes: macros from `_macros.html`; context vars `videos`, `classifications`, `current_classification`, `upload_token`, `splash_images` (provided by Task 6).
- Produces: the full page, linking `/assets/app/videos.css` and `/assets/app/videos.js`, with the inline `window.UPLOAD_TOKEN` bootstrap.

- [ ] **Step 1: Write the file**

Create `views/templates/videos_page.html` with exactly:

```jinja
{% import "_macros.html" as m %}<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Patata Videos</title>
<meta name="theme-color" content="#111111">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Videos">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
{{ m.splash_links(splash_images) }}
<link rel="manifest" href="/manifest.webmanifest">
<link rel="stylesheet" href="/assets/vendor/nprogress.css">
<link rel="stylesheet" href="/assets/app/videos.css">
</head>
<body>
<script src="/assets/vendor/nprogress.js"></script>
<button type="button" id="upload-fab" aria-label="Upload video" onclick="document.getElementById('upload-dialog').showModal()">+</button>
<dialog id="upload-dialog">
  <form id="upload-form">
    <h3>Upload video</h3>
    <input type="file" id="upload-file-input" accept="video/*" required>
    <select id="upload-classification">
      {% for cls in classifications %}<option value="{{ cls }}">{{ cls }}</option>{% endfor %}
    </select>
    <p id="upload-error" style="display:none;color:#f66;font-size:0.85em"></p>
    <div class="dialog-actions">
      <button type="button" onclick="document.getElementById('upload-dialog').close()">Cancel</button>
      <button type="submit">Upload</button>
    </div>
  </form>
</dialog>
<script>
(function(){
  var params=new URLSearchParams(window.location.search);
  var cls=params.get('classification');
  if(cls){
    document.cookie='preferred_classification='+encodeURIComponent(cls)+';path=/;max-age=31536000;SameSite=Lax';
  }else{
    var m=document.cookie.match(/(?:^|;\s*)preferred_classification=([^;]+)/);
    if(m){window.location.replace('/?classification='+m[1]);}
  }
})();
</script>
<h2 style="text-align:center;margin-bottom:12px;font-size:1.1em;max-width:900px;margin-left:auto;margin-right:auto">Patata Videos</h2>
{{ m.nav(classifications, current_classification) }}
<div class="grid">
{% for v in videos %}{{ m.card(v, classifications, current_classification, upload_token) }}
{% else %}<p style="color:#aaa;text-align:center">No videos yet.</p>{% endfor %}
</div>
<script>window.UPLOAD_TOKEN = {{ upload_token | tojson }};</script>
<script src="/assets/app/videos.js"></script>
</body>
</html>
```

Note: the inline cookie script uses single-backslash `\s` (this is now literal
HTML text, not a Python string). The `{% else %}` inside the `{% for %}` is
Jinja's empty-loop fallback — it renders "No videos yet." when `videos` is empty.

- [ ] **Step 2: Commit**

```bash
git add views/templates/videos_page.html
git commit -m "feat: add Jinja videos page template"
```

---

### Task 6: Create views/render.py with filters and build_videos_page (TDD)

**Files:**
- Create: `views/render.py`
- Create: `tests/test_render.py`

**Interfaces:**
- Consumes: `views/serializers.preview_url_for`; `db.CLASSIFICATIONS`; templates from Tasks 4–5.
- Produces: `SPLASH_STARTUP_IMAGES` (tuple), and `build_videos_page(videos, classifications, current_classification) -> str`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_render.py`:

```python
from views.render import build_videos_page
from db import CLASSIFICATIONS


def _video(**kw):
    base = {
        "id": 1,
        "url": "https://x.com/user/status/1234567890",
        "title": None,
        "status": "done",
        "platform": "twitter",
        "source": "download",
        "classification": "children",
        "error_msg": None,
        "preview_url": None,
    }
    base.update(kw)
    return base


def test_renders_done_card():
    html = build_videos_page([_video()], CLASSIFICATIONS, "children")
    assert 'class="card"' in html
    assert "/videos/1/stream" in html


def test_status_variants():
    videos = [
        _video(id=1, status="done"),
        _video(id=2, status="error", error_msg="boom"),
        _video(id=3, status="queued"),
    ]
    html = build_videos_page(videos, CLASSIFICATIONS, "children")
    assert "Error: boom" in html
    assert "Video is queued" in html


def test_named_title_used_for_youtube():
    html = build_videos_page(
        [_video(platform="youtube", title="My Clip")], CLASSIFICATIONS, "children"
    )
    assert "My Clip" in html


def test_empty_state():
    html = build_videos_page([], CLASSIFICATIONS, None)
    assert "No videos yet." in html


def test_no_delimiter_leaks():
    html = build_videos_page([_video()], CLASSIFICATIONS, "children")
    assert "{{" not in html
    assert "{%" not in html


def test_dialog_and_assets_present():
    html = build_videos_page([], CLASSIFICATIONS, None)
    assert 'id="upload-dialog"' in html
    assert "/assets/app/videos.css" in html
    assert "/assets/app/videos.js" in html
    assert "window.UPLOAD_TOKEN" in html
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python_env/bin/python -m pytest tests/test_render.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'views.render'`.

- [ ] **Step 3: Write the implementation**

Create `views/render.py`:

```python
import os
import re

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
    """preview_url_for's result, with our upload token attached when it points
    at our own token-gated endpoint (external thumbnail URLs need none)."""
    url = preview_url_for(video)
    if url and url.startswith("/videos/"):
        token = os.getenv("UPLOAD_TOKEN", "")
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}token={token}"
    return url


def _display_name(video: dict) -> str:
    """Named title for youtube/upload/library rows; otherwise the URL truncated."""
    has_named_title = video.get("platform") in ("youtube", "upload") or video.get("source") == "library"
    if has_named_title and video.get("title"):
        return video["title"]
    url = video.get("url", "")
    return url[:60] + ("…" if len(url) > 60 else "")


def _download_name(video: dict) -> str:
    """Filesystem-safe download filename stem (no extension)."""
    raw_name = video.get("title") or f"video_{video['id']}"
    safe_name = re.sub(r'[\\/:*?"<>|]', "_", raw_name).strip()
    return safe_name or f"video_{video['id']}"


_env = Environment(
    loader=FileSystemLoader("views/templates"),
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python_env/bin/python -m pytest tests/test_render.py -v`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add views/render.py tests/test_render.py
git commit -m "feat: add views/render.py Jinja renderer with smoke tests"
```

---

### Task 7: Wire router, serve app assets, delete old module

**Files:**
- Modify: `router.py` (import at line 23; add `APP_DIR` near `VENDOR_DIR` line 39; add route near the `/assets/vendor/{filename}` handler ~line 522)
- Delete: `views/templates.py`
- Modify: `tests/test_render.py` (add asset-route test) — OR add to an existing api test; instructions below use the app's TestClient pattern.

**Interfaces:**
- Consumes: `build_videos_page` from `views.render`; existing `VENDOR_MIME_TYPES` map and `_static_asset_response`/`FileResponse` pattern.
- Produces: `GET /assets/app/{filename}` serving css/js.

- [ ] **Step 1: Swap the import**

In `router.py` line 23, change:

```python
from views.templates import SPLASH_STARTUP_IMAGES, build_videos_page
```

to:

```python
from views.render import build_videos_page
```

(`SPLASH_STARTUP_IMAGES` was unused in `router.py` — drop it. Verify with
`grep -n SPLASH_STARTUP_IMAGES router.py` → should be no matches after the edit.)

- [ ] **Step 2: Add the app asset dir constant**

Near `VENDOR_DIR = Path("assets/vendor")` (line 39), add:

```python
APP_DIR = Path("assets/app")
APP_MIME_TYPES = {".css": "text/css", ".js": "text/javascript"}
```

- [ ] **Step 3: Add the route**

Immediately after the existing `vendor_asset` handler (the
`@router.get("/assets/vendor/{filename}", ...)` function ending ~line 531), add:

```python
@router.get("/assets/app/{filename}", include_in_schema=False)
async def app_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = APP_DIR / safe_name
    media_type = APP_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)
```

- [ ] **Step 4: Delete the old module**

Run: `git rm views/templates.py`
Expected: `rm 'views/templates.py'`.

- [ ] **Step 5: Add an asset-route test**

Append to `tests/test_render.py`:

```python
def test_app_asset_route_serves_css_and_js(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "t.db"))
    monkeypatch.setenv("UPLOAD_TOKEN", "secret")
    import importlib
    import db as db_module
    import router as router_module
    import main as main_module
    importlib.reload(db_module)
    importlib.reload(router_module)
    importlib.reload(main_module)
    from fastapi.testclient import TestClient

    with TestClient(main_module.app) as client:
        css = client.get("/assets/app/videos.css")
        js = client.get("/assets/app/videos.js")
        missing = client.get("/assets/app/nope.txt")

    assert css.status_code == 200
    assert css.headers["content-type"].startswith("text/css")
    assert js.status_code == 200
    assert "text/javascript" in js.headers["content-type"]
    assert missing.status_code == 404
```

If the `client` fixture in `tests/test_api.py` already reloads db/router/main
this way, prefer reusing that fixture instead of the inline reload — check
`tests/test_api.py` first and match its pattern.

- [ ] **Step 6: Run the full render test file**

Run: `python_env/bin/python -m pytest tests/test_render.py -v`
Expected: all tests PASS (the 6 from Task 6 plus the asset-route test).

- [ ] **Step 7: Run the whole suite for regressions**

Run: `python_env/bin/python -m pytest tests/ -q`
Expected: no new failures versus the pre-migration baseline.

- [ ] **Step 8: Smoke-test the live page**

Run: `./serve` in one shell, then in another:
`curl -s "http://127.0.0.1:3050/" | grep -c "/assets/app/videos.css"`
Expected: `1`. Also confirm `curl -s http://127.0.0.1:3050/assets/app/videos.js | head -1` returns JS, not a 404. Stop the server.

- [ ] **Step 9: Commit**

```bash
git add router.py tests/test_render.py
git commit -m "refactor: serve app assets and render via views.render; drop templates.py"
```

---

## Self-Review

**Spec coverage:**
- Add Jinja2 dep → Task 1. ✓
- Extract CSS to `assets/app/videos.css` → Task 2. ✓
- Extract JS to `assets/app/videos.js`, read `window.UPLOAD_TOKEN` → Task 3. ✓
- `_macros.html` (card/classification_menu/splash_links/nav) → Task 4. ✓
- `videos_page.html` with asset links + token bootstrap → Task 5. ✓
- `views/render.py`: Environment (autoescape), filters `preview_src`/`display_name`/`download_name`, `SPLASH_STARTUP_IMAGES`, unchanged `build_videos_page` signature → Task 6. ✓
- Drop `_status_badge` dead code → not carried into `render.py` (Task 6). ✓
- `/assets/app/{filename}` route mirroring vendor → Task 7. ✓
- router import swap + drop unused `SPLASH_STARTUP_IMAGES` import → Task 7. ✓
- Delete `views/templates.py` → Task 7. ✓
- `tests/test_render.py` smoke test: each status, empty list, key markup, no delimiter leaks → Tasks 6–7. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases". CSS/JS extraction references exact source line ranges plus an explicit transform — concrete, not vague. ✓

**Type consistency:** Filters named `preview_src`/`display_name`/`download_name` in Task 6 match the `| preview_src` / `| display_name` / `| download_name` uses in the Task 4 macros. `build_videos_page` context keys (`videos`, `classifications`, `current_classification`, `upload_token`, `splash_images`) match the vars referenced in Tasks 4–5 templates. `APP_DIR`/`APP_MIME_TYPES` defined and used within Task 7. ✓
