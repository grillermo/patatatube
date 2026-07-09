# Jinja templates migration — design

## Goal

Migrate `views/templates.py` (a 23.8 KB Python module that builds the videos
page as a giant f-string) to Jinja2 templates, separating Python from HTML/CSS/JS
as cleanly as possible. Output should be byte-identical modulo whitespace — this
is a mechanical extraction, not a behavior change.

## Current state

- `views/templates.py` contains:
  - `SPLASH_STARTUP_IMAGES` — data tuple of apple-touch-startup-image specs.
  - Helpers that mix data-prep with HTML string building: `_status_badge`
    (dead code — never called), `_preview_src`, `_splash_startup_link`,
    `_splash_startup_links`, `_classification_menu`.
  - `build_videos_page(videos, classifications, current_classification)` — one
    f-string with `<head>`, ~50 lines inline CSS, page HTML, and ~250 lines
    inline JS. All `{`/`}` are doubled for the f-string.
- Called once: `router.py:729` in `videos_page()`.
- Imported at `router.py:23`: `from views.templates import SPLASH_STARTUP_IMAGES, build_videos_page`. `SPLASH_STARTUP_IMAGES` is **unused** in router.py (droppable).
- No tests reference the module.
- `jinja2` not yet in `requirements.txt`.
- Asset serving precedent: `/assets/vendor/{filename}` route handler in
  `router.py` (~line 522) with a mime-type map and `Path(...).name` traversal guard.

## Decisions (from brainstorming)

1. **Extract CSS and JS to static files** — not kept inline. `.html` template
   holds only HTML.
2. **Logic lives in the template** via Jinja macros + custom filters. Python
   passes raw video dicts; branching/URL-building happens in template language.
3. **Everything under `views/`** — module renamed to `views/render.py`,
   templates in `views/templates/`.

## Target file layout

```
views/render.py                    # Jinja Environment + filters + build_videos_page + SPLASH_STARTUP_IMAGES
views/templates/videos_page.html   # head, splash, nav, grid loop, upload dialog, asset <link>/<script> tags
views/templates/_macros.html       # card(), classification_menu(), splash_links(), nav()
assets/app/videos.css              # the CSS block, braces un-doubled
assets/app/videos.js               # all the JS, braces un-doubled, reads window.UPLOAD_TOKEN
```

`views/templates.py` is deleted.

## Components

### `views/render.py`

- Holds `SPLASH_STARTUP_IMAGES` (moved verbatim from `templates.py`).
- Creates a module-level Jinja `Environment`:
  - `loader=FileSystemLoader("views/templates")`
  - `autoescape=select_autoescape(["html"])` — replaces every manual
    `html.escape(...)` call.
- Registers custom filters:
  - `preview_src(v)` — `preview_url_for(v)` with our `UPLOAD_TOKEN` appended when
    the URL points at our own `/videos/...` endpoint (current `_preview_src` logic).
  - `display_name(v)` — named title (`platform in {youtube, upload}` or
    `source == "library"`) when present, else the URL truncated to 60 chars + `…`.
  - `download_name(name)` — sanitize `title` (or `video_{id}`) with
    `re.sub(r'[\\/:*?"<>|]', "_", ...)`, fallback `video_{id}`.
- `build_videos_page(videos, classifications, current_classification) -> str`:
  **unchanged signature.** Builds context and returns
  `env.get_template("videos_page.html").render(...)`.
- Context passed to the template: `videos`, `classifications`,
  `current_classification`, `upload_token` (from `os.getenv("UPLOAD_TOKEN", "")`),
  `splash_images` (`SPLASH_STARTUP_IMAGES`).

### `views/templates/_macros.html`

- `card(v, classifications, current_classification, upload_token)` — the per-video
  card. `{% if v.status == "done" %}` player + download link, `{% elif ==
  "error" %}` error line, `{% else %}` "is {status}…". Uses `display_name`,
  `preview_src`, `download_name` filters. Stream/download URLs server-rendered
  here with `upload_token`.
- `classification_menu(v, classifications, current_classification)` — the details/summary dropdown of classify forms (current `_classification_menu`).
- `splash_links(images)` — loops `SPLASH_STARTUP_IMAGES` emitting
  `<link rel="apple-touch-startup-image" ...>` (current `_splash_startup_link(s)`),
  plus the leading unconditional `apple-splash-optimized.jpg` link.
- `nav(classifications, current_classification)` — the classification nav bar.

### `views/templates/videos_page.html`

- `{% import "_macros.html" as m %}`.
- `<head>` with meta, icons, `{{ m.splash_links(splash_images) }}`, manifest,
  `<link rel="stylesheet" href="/assets/vendor/nprogress.css">`,
  `<link rel="stylesheet" href="/assets/app/videos.css">`.
- Body: preferred-classification cookie script (inline, small), title,
  `{{ m.nav(...) }}`, grid loop `{% for v in videos %}{{ m.card(...) }}{% endfor %}`
  with the empty-state fallback, upload dialog markup.
- Before `videos.js`: inline bootstrap
  `<script>window.UPLOAD_TOKEN = {{ upload_token|tojson }};</script>`, then
  `<script src="/assets/app/nprogress.js">`… (keep vendor nprogress as-is) and
  `<script src="/assets/app/videos.js"></script>`.

### `assets/app/videos.css`, `assets/app/videos.js`

- Content moved out of the f-string with `{{`→`{` and `}}`→`}` un-doubling.
- `videos.js` reads `window.UPLOAD_TOKEN` instead of the templated
  `var UPLOAD_TOKEN = {upload_token_json}`.

### `router.py`

- Import: `from views.render import build_videos_page` (drop unused
  `SPLASH_STARTUP_IMAGES`).
- Add `/assets/app/{filename}` route mirroring the `/assets/vendor/{filename}`
  handler: `Path(filename).name` traversal guard, mime map for `.css`/`.js`,
  `FileResponse`, `include_in_schema=False`. New `APP_DIR = Path("assets/app")`.

## Token to external JS

JS files can't be templated. `videos_page.html` emits
`window.UPLOAD_TOKEN = {{ upload_token|tojson }}` inline before loading
`videos.js`; the JS reads the global. `tojson` safely encodes any token value.
Stream/download URLs remain server-rendered in the `card` macro.

## Testing

Add `tests/test_render.py`:
- Render `build_videos_page` with sample videos covering each status
  (`done`, `error`, `queued`/`downloading`) plus an empty list.
- Assert key markup present (a card, the nav, the upload dialog, the asset
  `<link>`/`<script>` refs).
- Assert no Jinja delimiter leaks (`{{`, `{%`) remain in the output.
- Follows the existing test conventions; no async marker needed (pure function).

## Out of scope

- Manifest route, splash/icon binaries, PWA behavior.
- Any JS/CSS logic change — extraction only.
- Other pages/endpoints (this is the only server-rendered HTML page).
```
