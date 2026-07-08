# File upload modal — design

## Goal

Let a user upload a video file directly from disk on `videos_page`, instead of only pasting Twitter/YouTube URLs. A "+" button top-right opens a modal with a file picker and a classification dropdown; submitting adds the video to the library alongside downloaded/library videos.

## Backend

### New endpoint: `POST /upload/file`

- Multipart body: `file` (the video), `classification` (string, must be in `db.CLASSIFICATIONS`).
- Gated by the existing `_check_token` (Authorization: Bearer header) — same as `/upload`.
- Handler streams the upload to a temp file (chunked reads, not one `await file.read()` of the whole body), then:
  ```python
  video_id = db.add_video(str(tmp_path), platform="upload", title=stem_of(file.filename))
  services.apply_classification(video_id, classification)
  background_tasks.add_task(process_uploaded_video, video_id)
  return {"id": video_id, "status": "queued"}  # 202, same shape as /upload
  ```
- If `classification` isn't in `CLASSIFICATIONS`, `400`.

### `downloader.process_uploaded_video(video_id)`

Mirrors `download_video`'s shape and failure handling:

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

Reuses `_store_ios_compatible_video` (ffmpeg normalize → move to `videos/{id}.mp4` → cleanup) as-is — no new ffmpeg code. Matches the existing convention: failures delete the row rather than setting an error status.

### `url` column reuse — and the leak it creates

`add_video`'s `url` param is repurposed to hold the temp file's local filesystem path so `process_uploaded_video` can find it without a new column. This is the same pattern `library.py` already uses (`url` = raw `source_path` for library rows) and it has the same problem: that path must never reach the API or the page.

Two fixes required, matching the existing `source == "library"` redaction in `views/serializers.py`:

1. **`serialize_video`**: add a branch redacting `url` to `""` when `video.get("platform") == "upload"`, same as the library branch (comment explaining why, same as the existing one).
2. **`views/templates.py` `build_videos_page`**: add `platform == "upload"` to the `has_named_title` check so the filename-derived `title` is shown instead of falling back to the raw (post-redaction, empty) `url`.

No new column, no migration.

## Frontend (`views/templates.py`)

### Button + modal markup

- "+" button, top-right, fixed position alongside the existing nav — opens a native `<dialog id="upload-dialog">`.
- Modal contents: `<input type="file" accept="video/*" required>`, `<select>` populated from `CLASSIFICATIONS` (same list `_classification_menu` already iterates), submit button, inline error `<p>` (hidden until an error occurs).

### Submit behavior

- `XMLHttpRequest`, not `fetch` — needed for `xhr.upload.onprogress` to drive real byte-level progress (`fetch` has no upload progress event).
- Sequence: `NProgress.start()` → `xhr.upload.onprogress` → `NProgress.set(loaded/total)` → on `load` with status 202, `NProgress.done()`, `dialog.close()`, `location.reload()` (new card shows up in its `queued`/`downloading` state, same as a fresh URL paste) → on error, `NProgress.done()`, show the inline error `<p>`, leave dialog open so the user can retry.
- Auth: add one JS const to the page's existing `<script>` block, `var UPLOAD_TOKEN = "{escaped token}";`, set as the XHR's `Authorization: Bearer` header. This is a new use of the token in JS; it does not touch the existing per-video query-string token usage on stream URLs (out of scope, left as-is).

### Vendoring nprogress

- `assets/vendor/nprogress.js` and `assets/vendor/nprogress.css` (MIT, pulled from the real upstream source, not reconstructed) checked into the repo — keeps the PWA fully offline-capable, no CDN fetch at runtime.
- New route `GET /assets/vendor/{filename}`, mirroring the existing `GET /assets/splash/{filename}` handler (path-restricted to the two known filenames, same static-file-serving shape).
- `<link>`/`<script>` tags added to `<head>`. Default nprogress styling (thin `#29d` top bar) is used as-is — reads fine against the page's `#111` background, no custom theming needed.

## Out of scope

- Drag-and-drop, multi-file upload, upload cancellation mid-transfer.
- Refactoring the existing per-video stream-URL token exposure.
- Client-side file-size/type validation beyond the `accept="video/*"` hint — ffmpeg normalize already rejects non-video input (raises, row gets deleted), consistent with how bad downloads are already handled.
