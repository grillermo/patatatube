# Send to Yoto — design

Send a PatataTube video's audio, as MP3, to the **English** card of the
yosubee user `hola@grillermo.com`. Both servers run on the macmini, so the
handoff is a localhost call carrying a file path — no media bytes over HTTP,
no internet round trip.

## Decisions (from the brainstorm)

| Question | Answer |
|---|---|
| How the file crosses | PatataTube sends the **path**; yosubee runs ffmpeg |
| Icon | Normal yosubee flow: run parks at `awaiting_icon`, pick in yosubee UI |
| Clients | **iOS only** |
| Feedback | Fire and forget: toast on yosubee's 202 |

## PatataTube

### Config (`.env`)

```
YOSUBEE_LOCAL_URL=http://localhost:3200/upload-from-video?user=hola@grillermo.com&playlist_name=English
YOSUBEE_LOCAL_TOKEN=<shared secret>
```

- Port **3200** is yosubee's Caddy listener, not a Rails port. Rails runs
  blue/green on 3201/3202 and only one slot is up between deploys, so a
  hardcoded Rails port would break every other deploy.
- Unset URL → the endpoint returns 503 (feature off), same as `UPLOAD_TOKEN`.

### Endpoint: `POST /api/videos/{id}/yoto`

- Bearer-gated (`_check_token`).
- 404 unknown id; **409** for library rows (`source='library'` / `plex_kind`
  non-null — no TV, no Movies) and for rows whose status isn't `done`.
- Builds the absolute path `paths.VIDEOS_DIR / f"{id}.mp4"` (resolved, so an
  external `MEDIA_ROOT` passes through as-is); 409 if the file is missing.
- `httpx.post(YOSUBEE_LOCAL_URL, json={"path": ..., "title": ...},
  headers={"X-Local-Token": ...}, timeout=5, trust_env=False)` — the
  `trust_env=False` convention from CLAUDE.md applies.
- yosubee 2xx → **202** `{"status": "sent"}`; anything else (non-2xx,
  connect error, timeout) → **502** with yosubee's error message if any.
- No ffmpeg here, so the "ffmpeg runs only in converter.py" invariant is
  untouched. No DB column, no job — fire and forget.

### iOS

- `APIClient.sendToYoto(videoID:)` → `POST /api/videos/{id}/yoto`.
- A **Send to Yoto de Elisa** item in the video's menu, shown only when
  `plexKind == nil`.
- Toast "Sent to Yoto de Elisa" on 202; error toast with the message on failure.
- Needs a `./deploy`.

### Tests

- `tests/test_api.py`: 202 on success (httpx mocked, asserts path/title/token
  sent), 409 for a library row, 409 for a non-`done` row, 502 when yosubee
  errors, 503 when unconfigured, 401 without token.

## yosubee

### Route + controller

`POST /upload-from-video?user=<email>&playlist_name=<card title>`,
body `{"path": "...", "title": "..."}`, header `X-Local-Token`.

- Skips session auth and CSRF; instead
  `ActiveSupport::SecurityUtils.secure_compare` against `ENV["LOCAL_UPLOAD_TOKEN"]`
  (unset → 503). **The token is required, not optional:** the Cloudflare
  tunnel lands on the same `:3200`, so every request — external ones too —
  looks local to Rails.
- `User.find_by(email:)` → 404 if missing.
- Card: `YotoApiClient#list_cards`, match the card whose title equals
  `playlist_name`. 422 if none, 422 if more than one.
- Path: must resolve (realpath) under `ENV["PATATATUBE_MEDIA_ROOT"]` and end
  in `.mp4`; 422 otherwise. Stops the endpoint from reading arbitrary files.
- Creates the run (below) and returns **202** `{"job_id": run.id}`.

### New upload source: `local`

- `UploadSource::LocalSource` alongside `YoutubeSource` / `GdriveSource`:
  - `queue` → `:gdrive` lane reuse, or a new `:local` queue (whichever the
    Solid Queue config already makes cheapest — decide at implementation).
  - `downloader` → `LocalAudioConvertService`: `ffmpeg -i <path> -vn
    -c:a libmp3lame -q:a 2 <workspace>/<title>.mp3`, reusing
    `DriveAudioDownloadService`'s `FFMPEG_PATH` and `run_ffmpeg` shape.
  - `resolve_title(run)` → `run.title` (passed in by PatataTube).
- `UploadRun`: `upload_url` stores `file://<path>`; `download_source` /
  `upload_url_must_be_supported` accept `file://` only when `source == "local"`
  (the public form can never produce it — `UploadInput` doesn't classify it).
- Run starts through the normal `start_processing!`, so `DownloadAudioJob`
  (convert + upload to Yoto) and `PrepareIconsJob` (search word + candidates,
  parks at `awaiting_icon`) run in parallel exactly as for YouTube. You pick
  the icon in yosubee's dashboard; finalize appends the chapter to the
  English card.
- Upload limit / credits: applies as for any other run (it's the same user).

### Tests

- Request spec: 202 creates a `local` run on the right card; 401 bad token;
  503 unset token; 404 unknown user; 422 no/ambiguous card; 422 path outside
  the media root.
- Service spec for `LocalAudioConvertService` with a stub ffmpeg.
