# File Upload Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "+" upload button to `videos_page` that opens a modal for picking a local video file and a classification, uploads it with a live progress bar, and adds it to the library alongside downloaded/library videos.

**Architecture:** New `POST /upload/file` endpoint (multipart, token-gated like the existing `/upload`) writes the incoming file to a temp path, inserts a `videos` row with `platform="upload"`, and schedules a new `downloader.process_uploaded_video` background task that reuses the existing ffmpeg-normalize-and-move pipeline (`_store_ios_compatible_video`). The temp path is stashed in the `url` column (same trick `library.py` already uses for `source_path`) and redacted from API output. The frontend is a native `<dialog>` submitted via `XMLHttpRequest` (for real upload-progress events) driving a vendored NProgress bar.

**Tech Stack:** FastAPI (`python-multipart`, already a dependency), vanilla JS (`XMLHttpRequest`, native `<dialog>`), vendored NProgress 0.2.0 (MIT).

## Global Constraints

- No new DB column/migration — `url` column is repurposed for the temp path, exactly as `library.py` already does for `source_path`.
- Classification values must come from `db.CLASSIFICATIONS` (`["children", "adults", "education", "tv", "movies"]`) — no hardcoded lists.
- `_check_token` (Authorization: Bearer header) gates the new endpoint — same as `/upload`, not `_check_token_or_query`.
- NProgress is vendored into `assets/vendor/` and served locally — no CDN fetch at runtime (PWA must stay offline-capable).
- Follow existing failure convention: background-task failures delete the row rather than setting an `error` status (see `download_video` in `downloader.py`).

---

### Task 1: `downloader.process_uploaded_video`

**Files:**
- Modify: `downloader.py` (add function after `download_video`, before `_download_twitter`, around line 50)
- Test: `tests/test_downloader.py`

**Interfaces:**
- Consumes: `db.get_video`, `db.update_video`, `db.delete_video`, `db.add_video` (all existing), `downloader._store_ios_compatible_video(video_id: int, downloaded_path: Path) -> str` (existing, unchanged)
- Produces: `downloader.process_uploaded_video(video_id: int) -> None` (coroutine) — Task 3's router endpoint schedules this via `background_tasks.add_task`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_downloader.py` (uses the existing `downloader_env` fixture already defined at the top of that file):

```python
@pytest.mark.asyncio
async def test_process_uploaded_video_success(monkeypatch, downloader_env, tmp_path):
    db, downloader, videos_dir = downloader_env
    tmp_upload = tmp_path / "upload123.mp4"
    tmp_upload.write_bytes(b"uploaded-bytes")
    video_id = db.add_video(str(tmp_upload), platform="upload", title="My Video")

    async def fake_normalize(path):
        return Path(path)

    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    await downloader.process_uploaded_video(video_id)

    video = db.get_video(video_id)
    assert video["status"] == "done"
    assert video["filename"] == f"{video_id}.mp4"
    assert (videos_dir / f"{video_id}.mp4").exists()
    assert not tmp_upload.exists()


@pytest.mark.asyncio
async def test_process_uploaded_video_failure_deletes_row_and_tmpfile(monkeypatch, downloader_env, tmp_path):
    db, downloader, videos_dir = downloader_env
    tmp_upload = tmp_path / "bad.mp4"
    tmp_upload.write_bytes(b"not-a-real-video")
    video_id = db.add_video(str(tmp_upload), platform="upload", title="Bad Video")

    async def fake_normalize(path):
        raise RuntimeError("ffmpeg failed while normalizing video")

    monkeypatch.setattr(downloader, "_normalize_media_for_ios", fake_normalize)

    await downloader.process_uploaded_video(video_id)

    assert db.get_video(video_id) is None
    assert not tmp_upload.exists()


@pytest.mark.asyncio
async def test_process_uploaded_video_unknown_id_raises(downloader_env):
    db, downloader, videos_dir = downloader_env
    with pytest.raises(ValueError):
        await downloader.process_uploaded_video(99999)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_downloader.py -k process_uploaded_video -v`
Expected: FAIL with `AttributeError: module 'downloader' has no attribute 'process_uploaded_video'`

- [ ] **Step 3: Implement `process_uploaded_video`**

In `downloader.py`, insert immediately after the `download_video` function (which ends with `db.delete_video(video_id)` around line 49):

```python
async def process_uploaded_video(video_id: int):
    video = db.get_video(video_id)
    if not video:
        raise ValueError(f"Unknown video id: {video_id}")

    db.update_video(video_id, status="downloading")
    tmp_path = Path(video["url"])
    try:
        dest_name = await _store_ios_compatible_video(video_id, tmp_path)
        db.update_video(video_id, status="done", filename=dest_name)
    except Exception as exc:
        logger.warning("Upload processing failed; deleting video row %s: %s", video_id, exc)
        db.delete_video(video_id)
        with suppress(FileNotFoundError):
            tmp_path.unlink()
```

No new imports needed — `Path`, `suppress`, `db`, and `logger` are already imported at the top of `downloader.py`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_downloader.py -k process_uploaded_video -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add downloader.py tests/test_downloader.py
git commit -m "feat: add process_uploaded_video background task"
```

---

### Task 2: Redact upload temp path from `serialize_video`

**Files:**
- Modify: `views/serializers.py`
- Test: `tests/test_serializers.py`

**Interfaces:**
- Consumes: nothing new
- Produces: `serialize_video` now redacts `url` to `""` whenever `video.get("platform") == "upload"` — Task 5's page rendering relies on `has_named_title` (not this redaction) to display something better than a blank/tmp-path url.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_serializers.py`:

```python
def test_serialize_upload_video_redacts_tmp_path_from_url():
    row = {
        "id": 12, "url": "/tmp/tmpabc123.mp4", "title": "My Upload",
        "platform": "upload", "status": "queued", "classification": "children",
    }
    data = serialize_video(row)
    assert data["url"] == ""
    assert data["title"] == "My Upload"
    assert data["platform"] == "upload"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_serializers.py -k redacts_tmp_path -v`
Expected: FAIL — `assert data["url"] == ""` fails because `data["url"]` is `"/tmp/tmpabc123.mp4"`

- [ ] **Step 3: Implement the redaction**

In `views/serializers.py`, the function currently ends with:

```python
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
```

Change the ending to add an `upload` branch right before `return data`:

```python
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
        # `url` holds the local temp-file path process_uploaded_video reads
        # to locate the upload before moving it into videos/{id}.mp4 — same
        # leak risk as the library source_path above, same fix.
        data["url"] = ""
    return data
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_serializers.py -k redacts_tmp_path -v`
Expected: 1 passed

- [ ] **Step 5: Run the full serializer test file to check for regressions**

Run: `python -m pytest tests/test_serializers.py -v`
Expected: all passed

- [ ] **Step 6: Commit**

```bash
git add views/serializers.py tests/test_serializers.py
git commit -m "fix: redact upload temp path from serialized video url"
```

---

### Task 3: `POST /upload/file` endpoint

**Files:**
- Modify: `router.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `downloader.process_uploaded_video(video_id: int)` (Task 1), `services.apply_classification(video_id: int, classification: str) -> bool` (existing), `db.CLASSIFICATIONS` (existing), `db.add_video` (existing)
- Produces: `POST /upload/file` — multipart fields `file`, `classification`; `202 {"id": int, "status": "queued"}` on success, `401` (missing/bad token), `400` (bad classification), `422` (missing fields, FastAPI's default). Task 5's frontend JS calls this exact path/shape.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py` (add `from pathlib import Path` to the top-of-file imports alongside the existing `import pytest` / `import importlib`):

```python
def test_upload_file_missing_token(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"classification": "children"},
    )
    assert resp.status_code == 401


def test_upload_file_invalid_classification(client):
    resp = client.post(
        "/upload/file",
        files={"file": ("video.mp4", b"bytes", "video/mp4")},
        data={"classification": "not-a-real-one"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 400


def test_upload_file_success(client, monkeypatch):
    queued = []
    monkeypatch.setattr("router.process_uploaded_video", lambda *a, **kw: queued.append((a, kw)))
    resp = client.post(
        "/upload/file",
        files={"file": ("my video.mp4", b"fake-video-bytes", "video/mp4")},
        data={"classification": "education"},
        headers={"Authorization": "Bearer test-secret"},
    )
    assert resp.status_code == 202
    data = resp.json()
    assert data["status"] == "queued"
    assert queued == [((data["id"],), {})]

    import db
    video = db.get_video(data["id"])
    assert video["platform"] == "upload"
    assert video["title"] == "my video"
    assert video["classification"] == "education"
    assert Path(video["url"]).exists()
    assert Path(video["url"]).read_bytes() == b"fake-video-bytes"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k upload_file -v`
Expected: FAIL — `404 Not Found` for all three (route doesn't exist yet)

- [ ] **Step 3: Implement the endpoint**

In `router.py`, change the fastapi import line (currently line 10):

```python
from fastapi import APIRouter, Form, HTTPException, Request, BackgroundTasks
```

to:

```python
from fastapi import APIRouter, File, Form, HTTPException, Request, BackgroundTasks, UploadFile
```

Add `import tempfile` to the top-level imports (alongside `import os`, `import re`, etc. — currently lines 1-9).

Change the downloader import (currently line 20):

```python
from downloader import download_video
```

to:

```python
from downloader import download_video, process_uploaded_video
```

Then add the new endpoint right after the existing `upload` function (which ends with `return {"id": video_id, "status": "queued"}` around line 210), before `def _guess_mime`:

```python
@router.post("/upload/file", status_code=202)
async def upload_file(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    classification: str = Form(...),
):
    _check_token(request)
    if classification not in CLASSIFICATIONS:
        raise HTTPException(status_code=400, detail="Invalid classification")

    suffix = Path(file.filename or "").suffix or ".mp4"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp_path = Path(tmp.name)
        while chunk := await file.read(1024 * 1024):
            tmp.write(chunk)

    stem = Path(file.filename or "").stem or None
    video_id = db.add_video(str(tmp_path), platform="upload", title=stem)
    services.apply_classification(video_id, classification)
    background_tasks.add_task(process_uploaded_video, video_id)
    return {"id": video_id, "status": "queued"}
```

`services` is already imported at the top of `router.py` (line 18); `CLASSIFICATIONS` is already imported (line 19).

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -k upload_file -v`
Expected: 3 passed

- [ ] **Step 5: Run the full API test file to check for regressions**

Run: `python -m pytest tests/test_api.py -v`
Expected: all passed

- [ ] **Step 6: Commit**

```bash
git add router.py tests/test_api.py
git commit -m "feat: add POST /upload/file endpoint"
```

---

### Task 4: Vendor NProgress and serve it from `/assets/vendor/{filename}`

**Files:**
- Create: `assets/vendor/nprogress.js`
- Create: `assets/vendor/nprogress.css`
- Modify: `router.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: nothing new
- Produces: `GET /assets/vendor/{filename}` serving `nprogress.js` (`application/javascript`) and `nprogress.css` (`text/css`), 404 for anything else. Task 5's `<head>` links to these exact paths.

- [ ] **Step 1: Vendor the real NProgress 0.2.0 source (pinned version, not reconstructed)**

```bash
mkdir -p assets/vendor
curl -sL https://cdn.jsdelivr.net/npm/nprogress@0.2.0/nprogress.js -o assets/vendor/nprogress.js
curl -sL https://cdn.jsdelivr.net/npm/nprogress@0.2.0/nprogress.css -o assets/vendor/nprogress.css
```

Verify both downloaded correctly:

```bash
head -c 80 assets/vendor/nprogress.js
```

Expected output starts with: `/* NProgress, (c) 2013, 2014 Rico Sta. Cruz - http://ricostacruz.com/nprogress`

```bash
wc -l assets/vendor/nprogress.js assets/vendor/nprogress.css
```

Expected: `476` lines for `nprogress.js`, `74` lines for `nprogress.css` (plus a `total` line).

- [ ] **Step 2: Write the failing tests**

Add to `tests/test_api.py`:

```python
def test_vendor_asset_serves_nprogress_js(client):
    resp = client.get("/assets/vendor/nprogress.js")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/javascript"


def test_vendor_asset_serves_nprogress_css(client):
    resp = client.get("/assets/vendor/nprogress.css")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "text/css; charset=utf-8"


def test_vendor_asset_404_for_unknown_file(client):
    resp = client.get("/assets/vendor/does-not-exist.js")
    assert resp.status_code == 404


def test_vendor_asset_rejects_path_traversal(client):
    resp = client.get("/assets/vendor/..%2Fmain.py")
    assert resp.status_code == 404
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k vendor_asset -v`
Expected: FAIL — `404 Not Found` for the two "serves" tests (route doesn't exist yet), so those two assert on status 200 fail; the 404 tests may spuriously pass already. Confirm by running `-k "serves_nprogress"` and seeing `assert 404 == 200` failures.

- [ ] **Step 4: Implement the route**

In `router.py`, add near the other directory constants (currently around line 31, right after `SPLASH_DIR = Path("assets/splash")`):

```python
VENDOR_DIR = Path("assets/vendor")
VENDOR_MIME_TYPES = {
    ".js": "application/javascript",
    ".css": "text/css",
}
```

Add the route right after `splash_asset` (which ends with `return FileResponse(target, media_type=media_type)` around line 488):

```python
@router.get("/assets/vendor/{filename}", include_in_schema=False)
async def vendor_asset(filename: str):
    safe_name = Path(filename).name
    if safe_name != filename:
        raise HTTPException(status_code=404, detail="Not found")
    target = VENDOR_DIR / safe_name
    media_type = VENDOR_MIME_TYPES.get(target.suffix.lower())
    if not target.exists() or media_type is None:
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(target, media_type=media_type)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -k vendor_asset -v`
Expected: 4 passed

- [ ] **Step 6: Commit**

```bash
git add assets/vendor/nprogress.js assets/vendor/nprogress.css router.py tests/test_api.py
git commit -m "feat: vendor NProgress and serve it from /assets/vendor"
```

---

### Task 5: Upload button, modal, and submit JS on `videos_page`

**Files:**
- Modify: `views/templates.py`
- Test: `tests/test_api.py`

**Interfaces:**
- Consumes: `POST /upload/file` (Task 3), `/assets/vendor/nprogress.js` + `/assets/vendor/nprogress.css` (Task 4), `db.CLASSIFICATIONS` (existing, already passed into `build_videos_page` as `classifications`)
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_api.py`:

```python
def test_videos_page_has_upload_button_and_dialog(client):
    resp = client.get("/videos")
    assert resp.status_code == 200
    assert 'id="upload-fab"' in resp.text
    assert 'id="upload-dialog"' in resp.text
    assert 'id="upload-form"' in resp.text
    assert '<option value="children">children</option>' in resp.text
    assert '<option value="tv">tv</option>' in resp.text


def test_videos_page_loads_vendored_nprogress(client):
    resp = client.get("/videos")
    assert '/assets/vendor/nprogress.js' in resp.text
    assert '/assets/vendor/nprogress.css' in resp.text


def test_videos_page_exposes_upload_token_for_xhr(client):
    resp = client.get("/videos")
    assert 'var UPLOAD_TOKEN = "test-secret";' in resp.text


def test_upload_platform_video_shows_filename_title_not_tmp_path(client):
    import db
    video_id = db.add_video("/private/tmp/tmpabc123.mp4", platform="upload", title="Birthday Clip")
    db.update_video(video_id, status="done", filename=f"{video_id}.mp4")
    resp = client.get("/videos")
    assert "Birthday Clip" in resp.text
    assert "tmpabc123" not in resp.text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tests/test_api.py -k "upload_button or upload_dialog or vendored_nprogress or exposes_upload_token or filename_title" -v`
Expected: FAIL — none of the new markup/JS exists yet

- [ ] **Step 3: Fix `has_named_title` to cover uploads**

In `views/templates.py`, inside `build_videos_page`, change:

```python
        has_named_title = v.get("platform") == "youtube" or v.get("source") == "library"
```

to:

```python
        has_named_title = v.get("platform") in ("youtube", "upload") or v.get("source") == "library"
```

- [ ] **Step 4: Build the classification `<option>` list and upload button/modal markup**

In `views/templates.py`, inside `build_videos_page`, right before the existing `nav_links` block:

```python
    nav_links = []
```

add, immediately before it:

```python
    upload_cls_options = "".join(
        f'<option value="{escape(cls, quote=True)}">{escape(cls)}</option>' for cls in classifications
    )
```

Then, right after the existing:

```python
    nav_html = f'<nav class="nav">{"".join(nav_links)}</nav>'
```

add:

```python
    upload_modal_html = f"""
    <button type="button" id="upload-fab" aria-label="Upload video" onclick="document.getElementById('upload-dialog').showModal()">+</button>
    <dialog id="upload-dialog">
      <form id="upload-form">
        <h3>Upload video</h3>
        <input type="file" id="upload-file-input" accept="video/*" required>
        <select id="upload-classification">
          {upload_cls_options}
        </select>
        <p id="upload-error" style="display:none;color:#f66;font-size:0.85em"></p>
        <div class="dialog-actions">
          <button type="button" onclick="document.getElementById('upload-dialog').close()">Cancel</button>
          <button type="submit">Upload</button>
        </div>
      </form>
    </dialog>"""
```

- [ ] **Step 5: Insert the vendor `<link>`, the modal markup, and the vendor `<script>` tag**

In `views/templates.py`, the `<head>` currently ends with:

```python
<link rel="manifest" href="/manifest.webmanifest">
<style>
```

Change to:

```python
<link rel="manifest" href="/manifest.webmanifest">
<link rel="stylesheet" href="/assets/vendor/nprogress.css">
<style>
```

The CSS block (inside that same `<style>` tag) currently ends with:

```python
  .menu-btn.active-cls{{color:#4a9eff}}
</style>
```

Change to:

```python
  .menu-btn.active-cls{{color:#4a9eff}}
  #upload-fab{{position:fixed;top:calc(12px + env(safe-area-inset-top));right:calc(12px + env(safe-area-inset-right));z-index:30;width:40px;height:40px;border-radius:50%;background:#4a9eff;color:#fff;border:none;font-size:1.4em;line-height:1;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,0.4)}}
  #upload-fab:active{{background:#3a8eef}}
  dialog#upload-dialog{{background:#1e1e1e;color:#eee;border:1px solid #3a3a3a;border-radius:10px;padding:16px;max-width:340px;width:90vw}}
  dialog#upload-dialog::backdrop{{background:rgba(0,0,0,0.6)}}
  dialog#upload-dialog h3{{margin-bottom:12px;font-size:1.1em}}
  dialog#upload-dialog input[type=file]{{width:100%;margin-bottom:12px;color:#eee}}
  dialog#upload-dialog select{{width:100%;padding:8px;margin-bottom:12px;background:#2a2a2a;color:#eee;border:1px solid #3a3a3a;border-radius:6px}}
  .dialog-actions{{display:flex;justify-content:flex-end;gap:8px}}
  .dialog-actions button{{padding:8px 16px;border-radius:6px;border:1px solid #3a3a3a;background:#2a2a2a;color:#eee;cursor:pointer;font-size:0.9em}}
  .dialog-actions button[type=submit]{{background:#4a9eff;border-color:#4a9eff}}
  #nprogress .bar{{background:#4a9eff}}
</style>
```

The `<body>` currently opens with:

```python
<body>
<script>
(function(){{
```

Change to (adds the vendor `<script>` tag before any inline script runs, and inserts `{upload_modal_html}` — the button lives at the top of `<body>`, not inside `.grid`, so it stays fixed-position regardless of scroll):

```python
<body>
<script src="/assets/vendor/nprogress.js"></script>
{upload_modal_html}
<script>
(function(){{
```

- [ ] **Step 6: Add the submit JS and the `UPLOAD_TOKEN` const**

The final `<script>` block currently ends with:

```python
window.addEventListener('pagehide', stopAllPreloads);
document.addEventListener('visibilitychange', function(){{
  if(document.hidden) stopAllPreloads();
}});
</script>
</body>
</html>"""
```

Change to:

```python
window.addEventListener('pagehide', stopAllPreloads);
document.addEventListener('visibilitychange', function(){{
  if(document.hidden) stopAllPreloads();
}});
</script>
<script>
var UPLOAD_TOKEN = "{escape(os.getenv('UPLOAD_TOKEN', ''), quote=True)}";

document.getElementById('upload-form').addEventListener('submit', function(e){{
  e.preventDefault();
  var fileInput = document.getElementById('upload-file-input');
  var clsSelect = document.getElementById('upload-classification');
  var errorEl = document.getElementById('upload-error');
  var file = fileInput.files[0];
  if(!file) return;

  errorEl.style.display = 'none';
  var formData = new FormData();
  formData.append('file', file);
  formData.append('classification', clsSelect.value);

  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/upload/file');
  xhr.setRequestHeader('Authorization', 'Bearer ' + UPLOAD_TOKEN);

  NProgress.start();
  xhr.upload.onprogress = function(evt){{
    if(evt.lengthComputable){{
      NProgress.set(evt.loaded / evt.total);
    }}
  }};
  xhr.onload = function(){{
    NProgress.done();
    if(xhr.status === 202){{
      document.getElementById('upload-dialog').close();
      window.location.reload();
    }} else {{
      errorEl.textContent = 'Upload failed (' + xhr.status + ')';
      errorEl.style.display = 'block';
    }}
  }};
  xhr.onerror = function(){{
    NProgress.done();
    errorEl.textContent = 'Upload failed — network error';
    errorEl.style.display = 'block';
  }};
  xhr.send(formData);
}});
</script>
</body>
</html>"""
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `python -m pytest tests/test_api.py -k "upload_button or upload_dialog or vendored_nprogress or exposes_upload_token or filename_title" -v`
Expected: 4 passed

- [ ] **Step 8: Run the full test suite**

Run: `python -m pytest tests/ -v`
Expected: all passed

- [ ] **Step 9: Manual smoke test**

```bash
./serve
```

Open `http://localhost:3050/videos` in a browser (set `UPLOAD_TOKEN` in `.env` first if not already set). Confirm:
- A circular "+" button appears fixed top-right.
- Clicking it opens the modal with a file picker and a classification dropdown (children/adults/education/tv/movies).
- Picking a small video file and clicking Upload shows a thin blue progress bar at the very top of the page while the file transfers.
- After the transfer completes, the modal closes and the page reloads with a new card showing "Video is downloading…" (then "done" once ffmpeg finishes, on a manual refresh).
- The new card, once done, shows the uploaded file's original filename (minus extension) as its title — not a `/tmp/...` path.

- [ ] **Step 10: Commit**

```bash
git add views/templates.py tests/test_api.py
git commit -m "feat: add upload button and modal to videos_page"
```

---

## Self-Review Notes

- **Spec coverage:** "+" button top-right → Task 5 Step 4/5. Modal with file input + classification `<select>` → Task 5 Step 4. Upload adds video alongside others → Tasks 1–3 (endpoint + background processing). `url` leak (raised during brainstorming, not in the original one-line spec but required by the chosen design) → Task 2. NProgress vendoring → Task 4. All covered.
- **Placeholder scan:** no TBD/TODO; every step has real code or an exact command.
- **Type consistency:** `process_uploaded_video(video_id: int)` — same signature used in Task 1's definition, Task 3's `background_tasks.add_task(process_uploaded_video, video_id)`, and Task 1's tests. `upload_cls_options` / `upload_modal_html` names are consistent between Step 4 and Step 5 of Task 5.
