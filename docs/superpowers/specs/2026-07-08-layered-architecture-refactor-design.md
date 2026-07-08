# Layered Architecture Refactor — Design

Date: 2026-07-08

## Goal

Restructure the PatataTube FastAPI backend from its current flat module layout
into an explicit layered architecture (controllers / models / schemas / services
/ data access), migrating the hand-rolled SQLite layer to **SQLModel** with
**Alembic** migrations. This is a **behavior-preserving** refactor: same routes,
same JSON API shape, same on-disk DB file, same SSR HTML. The iOS app is
untouched because the API contract does not change.

## Non-goals

- No new features.
- No async DB engine (stays synchronous, matching current blocking behavior).
- No behavior changes. Known warts (blocking DB calls inside async handlers, the
  `DB_PATH` default mismatch between `.db` and `.sqlite` in `db.py`) are
  **preserved as-is**, not fixed here.
- No changes to `ios/`.

## Locked decisions

| Decision | Choice |
|----------|--------|
| ORM | SQLModel |
| Migrations | Alembic (baseline revision matching current schema; existing prod DB `alembic stamp`ed) |
| Data-access layer | Dedicated `repositories/` package |
| Row shape | Return SQLModel **model instances** (not dicts) |
| DB engine | Synchronous (`create_engine` + `Session`) |
| Tests | Rewritten to new import paths / dependency overrides |
| Scope | Pure restructure, behavior-preserving |

## Target structure

```
app/
├── main.py                 # app init, lifespan, middleware, router mounting only
├── config.py               # pydantic-settings: UPLOAD_TOKEN, paths, ffmpeg bins,
│                           #   stream limit, ALLOWED_HOSTS, CLASSIFICATIONS home
├── database.py             # SQLModel engine + Session factory; WAL + busy_timeout pragmas
├── api/
│   ├── dependencies.py     # get_session; require_token (Bearer); require_token_or_query
│   └── v1/
│       ├── videos.py       # /api/videos*, delete, prepare, /api/classifications
│       ├── library.py      # /api/library/scan
│       ├── streaming.py    # /videos/{id}/stream, /preview, /hls/*  (byte-range + HLS)
│       ├── pages.py        # SSR GET / and /videos + form endpoints (move/classify/version)
│       └── assets.py       # favicon, apple-touch-icon, splash, manifest.webmanifest
├── models/                 # SQLModel tables: Video, VideoVersion (+ relationship)
├── schemas/                # request/response Pydantic: Upload/Move/Classify/Version, VideoOut
├── repositories/
│   └── videos.py           # all queries + version-sync logic from db.py
└── services/
    ├── videos.py           # apply_move, apply_classification, choose_version, delete, prepare
    ├── downloader.py       # download_video + ffmpeg normalize (from downloader.py)
    ├── library.py          # scan_library, convert_library_video, plan_conversion
    ├── hls.py              # (from hls.py)
    ├── subtitles.py        # (from subtitles.py)
    ├── plex.py             # (from plex.py)
    └── url_classifier.py   # _classify_url, _normalize_twitter_url, _extract_youtube_id
alembic/
├── env.py                  # wired to SQLModel metadata + DB_PATH env
└── versions/
    └── <baseline>.py       # matches current schema exactly
alembic.ini
```

`views/templates.py` (SSR HTML + PWA splash) stays as-is, consumed by
`api/v1/pages.py`. `version_namer.py` and `relabel_versions.py` remain utility
modules (referenced by `services/library.py`); place under `services/` or a
`utils/` module — final home decided in the plan, no logic change.

## Layer responsibilities

### models/

Two SQLModel table classes mirroring the **current** schema exactly (every
column in `db.init_db`):

- `Video` — `id, url, platform, source_key, title, filename, status, error_msg,
  created_at, preview_url, position, classification, source, source_path,
  converted_path, show_title, season, episode, summary, plex_rating_key,
  show_rating_key, deleted_at, chosen_version_id, hls_status`.
  Relationship: `versions: list[VideoVersion]`.
- `VideoVersion` — `id, video_id, source_path, label, status, converted_path,
  error_msg, position, created_at`; `UNIQUE(video_id, source_path)`.

`CLASSIFICATIONS` (`children, adults, education, tv, movies`) moves to a single
home (`config.py` or `models/`) and is imported everywhere validation happens.

### repositories/videos.py

Every `db.py` function becomes a repository function taking a `Session` and
returning model instances (or `None`/`bool`/scalars as today). The non-trivial
internals move here verbatim in behavior:

- `add_video`, `get_video`, `get_all_videos`, `delete_video`, `update_video`
- `get_completed_video_by_source`, `move_video`, `set_video_classification`,
  `set_hls_status`
- Version logic: `get_video_versions`, `get_video_version`, `set_chosen_version`,
  `get_version_labels`, `_ensure_chosen_version`, `_sync_video_from_chosen`,
  `_sync_versions`, `_incoming_versions`
- Library: `upsert_library_video`, `tombstone_video`, `get_converted_paths`,
  `set_library_state`

`_sync_video_from_chosen`'s denormalization of the chosen version onto the video
row is preserved (still needed so `/stream` and serializers read consistent
state).

### Backfills + init

The Python-side data backfills are **data fixes, not schema**, so they do not
become Alembic migrations. They run at startup in `lifespan` after Alembic has
brought the schema current: `_backfill_positions`,
`_backfill_youtube_preview_urls`, `_backfill_library_added_at`,
`_backfill_video_versions`, `_delete_error_videos`. Idempotency guards
(`_ADDED_AT_POSITION_FLOOR`, existence checks) are preserved. This keeps current
boot behavior identical.

WAL + `busy_timeout=30000` pragmas move to `database.py` engine construction
(via a `connect`/`PRAGMA` event on the engine) so every connection still gets
them, preserving multi-worker read/write concurrency.

### schemas/

- Request models (from `main.py`): `UploadRequest`, `MoveRequest`,
  `ClassifyRequest`, `VersionRequest`.
- Response: `VideoOut` replaces `serialize_video`. A `from_model(video, *,
  subtitle_tracks=None)` builder produces the exact current JSON, including:
  - `stream_path`, `hls_path` (gated by the `_hls_ready` logic, moved here),
  - library `url` redaction to `""` and `preview_url`/`show_preview_url` rewrites,
  - the `versions` array with **`is_chosen` computed** from
    `video.chosen_version_id` (no longer a stored/attached key),
  - `subtitle_tracks` supplied by the caller (detail endpoint), default `[]`.

### api/

Routers split by concern and mounted in `main.py`. Endpoints keep identical
paths, methods, status codes, and bodies. `api/dependencies.py`:

- `get_session()` — yields a `Session` from the factory (used by every endpoint
  that touches the DB).
- `require_token` — Bearer check (today's `_check_token`), as a dependency.
- `require_token_or_query` — Bearer-or-`?token=` (today's
  `_check_token_or_query`), as a dependency.

The SSR form endpoints (`/videos/{id}/move`, `/classify`, `/version`) stay
**un-gated** exactly as today; the `/api/*` equivalents keep `require_token`.

Byte-range helpers (`_parse_byte_range`, `_iter_file_range`,
`_range_not_satisfiable`), the streaming semaphore, static-asset caching, and
mime guessing move into `api/v1/streaming.py` / `api/v1/assets.py` (or small
helper modules they own). No logic change.

### services/

Thin orchestration over repositories; each service function receives a `Session`
(or opens one via the factory for background tasks). `services/videos.py`
mirrors today's `services.py` plus the delete/prepare orchestration currently
inline in `main.py`. `downloader`, `library`, `hls`, `subtitles`, `plex` move
with import-path updates only. `url_classifier` holds the URL normalization
logic extracted from `main.py`.

Background tasks (`download_video`, `convert_library_video`, `hls.prepare`) still
run via FastAPI `BackgroundTasks` on threads and manage their own `Session`
(they outlive the request, so they cannot use the request-scoped `get_session`
dependency).

## Alembic strategy

1. Add `alembic/` + `alembic.ini`; `env.py` reads `DB_PATH` (same env var) and
   targets `SQLModel.metadata`.
2. Author one **baseline** revision whose `upgrade()` produces the exact current
   schema (both tables, all columns, the two indexes, defaults).
3. Existing prod DB (`data/watch_later.sqlite`) is brought in with
   `alembic stamp <baseline>` (documented in README / a make step) so the
   baseline never runs against it.
4. Fresh installs run `alembic upgrade head` (invoked at startup or documented in
   `./serve` setup) to create the schema, then backfills run.

Startup order in `lifespan`: set process name → ensure dirs → `alembic upgrade
head` (or `create_all` fallback for tests) → run backfills → load static cache.
The exact "who runs upgrade" (lifespan vs. explicit command) is settled in the
plan; the constraint is that tests and fresh installs get a schema without a
manual step.

## Testing strategy

- Tests rewritten to import from the new packages. The current
  `reload(db); reload(main)` pattern (needed because modules read env at import)
  is replaced by: a fresh engine per test bound to a temp `DB_PATH`, and FastAPI
  `dependency_overrides[get_session]` where useful.
- Every existing test's assertions are preserved — same inputs, same expected
  outputs. Test files map: `test_db.py` → repository tests; `test_services.py` →
  service tests; `test_serializers.py` → schema (`VideoOut`) tests; `test_api.py`
  → API tests against the mounted routers; `test_downloader/library/hls/plex/
  subtitles/version_namer` → service tests with updated imports.
- New async tests keep the per-test `@pytest.mark.asyncio` marker (no global
  asyncio mode), per existing convention.

## Verification

- `python -m pytest tests/` fully green is the completion bar.
- Manual smoke: boot server against a **copy** of the prod DB, confirm `/`,
  `/videos`, `/api/videos`, a stream request with `Range`, and a library
  `/preview` all behave as before.
- Diff the `/api/videos` JSON for a representative row before/after to prove the
  shape is byte-identical.

## Risks

- **Model-instance ripple** — every consumer of the old dicts
  (`serialize_video`, `downloader`, `library`, tests) changes to attribute
  access. Highest-churn part; mitigated by preserving computed fields in
  `VideoOut` and porting logic verbatim.
- **Alembic against live data** — a mis-authored baseline that runs instead of
  stamps would attempt to recreate existing tables. Mitigated by the explicit
  `stamp` step and testing the baseline only against a fresh DB.
- **Startup races** — multiple uvicorn workers running `alembic upgrade`
  concurrently. Baseline is idempotent (`CREATE TABLE IF NOT EXISTS`-equivalent /
  Alembic version table guards); backfills keep their existing idempotency guards.
- **Behavior drift** — the safety net is the preserved test suite plus the
  before/after JSON diff.
