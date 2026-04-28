# Twitter Watch Later — Design Spec

**Date:** 2026-04-27

## Overview

Personal FastAPI app to download Twitter videos in the background and stream them later from a mobile-optimized HTML page, with per-video resume support.

## Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/upload` | Bearer token | Submit Twitter URL for background download |
| GET | `/videos` | — | Mobile-optimized HTML page with all videos |
| GET | `/videos/{id}/stream` | — | Byte-range video streaming |
| POST | `/videos/{id}/progress` | — | Save playback position (called by JS) |

## Authentication

`/upload` requires `Authorization: Bearer <token>` header. Token stored in `.env` as `UPLOAD_TOKEN`. All other endpoints are unauthenticated (personal tool, local network use).

## Background Download

FastAPI `BackgroundTasks` — response returns immediately with `202 Accepted` + video `id`. Download runs in-process after response. If server restarts mid-download, the row stays `status=downloading`; user re-submits the URL.

pybalt handles the actual Twitter video download. Downloaded files saved to `videos/` directory (gitignored).

## Database

SQLite via Python `sqlite3` stdlib. Two tables:

```sql
CREATE TABLE videos (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    url       TEXT NOT NULL,
    filename  TEXT,
    status    TEXT NOT NULL DEFAULT 'queued',  -- queued | downloading | done | error
    error_msg TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE progress (
    video_id        INTEGER PRIMARY KEY REFERENCES videos(id),
    position_seconds REAL NOT NULL DEFAULT 0
);
```

DB file: `data/watch_later.db` (gitignored).

## `/videos` HTML Page

- Plain HTML + inline CSS, no framework
- Single-column stacked layout, `max-width: 480px`, centered
- Each video card: title (URL), status badge, `<video>` player
- `<video>` attributes: `controls`, `playsinline`, `preload="metadata"`, `width="100%"`
- `currentTime` set from DB `progress.position_seconds` on page load (inlined into HTML)
- JS `timeupdate` listener, debounced 5s → `POST /videos/{id}/progress` with body `{"position_seconds": <float>}`
- Pending/downloading videos show status text, no player
- Error videos show error message

## Video Streaming

`GET /videos/{id}/stream` serves the file with HTTP byte-range support (`206 Partial Content`) so `<video>` elements can seek without downloading the whole file. FastAPI's `FileResponse` does not handle byte-range — implement a manual `StreamingResponse` that reads the `Range` header and returns the correct slice with `Content-Range` and `Accept-Ranges: bytes` headers.

## Project Structure

```
twitter-to-watch-later/
├── main.py          # FastAPI app, all routes
├── db.py            # SQLite helpers (init, queries)
├── downloader.py    # pybalt download logic
├── .env             # UPLOAD_TOKEN (not committed)
├── .env.example     # template
├── videos/          # downloaded video files (gitignored)
├── data/            # SQLite DB (gitignored)
└── requirements.txt
```

## Dependencies

```
fastapi
uvicorn
pybalt
python-dotenv
python-multipart
```

## Error Handling

- Invalid/missing token → `401 Unauthorized`
- Missing URL field → `422 Unprocessable Entity` (FastAPI default)
- pybalt download failure → update `status=error`, store message in `error_msg`
- Video file not found at stream time → `404`
- Byte-range out of bounds → `416 Range Not Satisfiable`

## .env Example

```
UPLOAD_TOKEN=your-secret-token-here
```
