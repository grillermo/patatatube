# Layered Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure PatataTube's backend into `models/ · schemas/ · repositories/ · services/ · api/` layers, migrating the hand-rolled SQLite layer (`db.py`) to SQLModel with Alembic migrations, with zero behavior change (same routes, same JSON shape, same DB file, iOS untouched).

**Architecture:** Bottom-up build order — `models` → `database` (engine) → `repositories` (queries, return model instances) → `schemas` (request/response Pydantic, replacing `serialize_video`) → `services` (orchestration, moved from `services.py`/`downloader.py`/`library.py`/etc.) → `api/v1/*` routers (replacing today's `router.py`) → `main.py` (pure wiring). Each layer is fully tested before the next depends on it.

**Tech Stack:** FastAPI, SQLModel, Alembic, SQLite (WAL), pytest + pytest-asyncio.

**Baseline note:** This plan assumes today's actual repo state: `main.py` was already split into `main.py` (app init) + `router.py` (all routes/handlers) + `middleware.py` (TrustedHostMiddleware **plus a Redis FIFO response cache**, `RedisCacheMiddleware`, backed by `cache.py`) in a prior session. This plan replaces `router.py`'s contents with the new `api/`, `services/`, `schemas/` layers — it does not start from the original single-file `main.py`.

**Repo drift since this plan was first written (2026-07-08 → now):** the following already-shipped changes are folded into the tasks below — read them before executing:
- **Manual reorder was removed.** `db.move_video`, `services.apply_move`, `MoveRequest`, the `api_move_video`/`move_video_endpoint` handlers, and the `/api/videos/{id}/move` + `/videos/{id}/move` routes no longer exist. Every reference to "move" in the tasks below has been struck — do not port it.
- **`CLASSIFICATIONS` is now `["children", "adults", "anabel", "tv", "movies"]`** (was `education`). Use this exact list in `config.py`.
- **Audio-language selection shipped.** New column `videos.audio_lang`, new `video_versions.audio_langs` / `video_versions.converted_langs` (JSON), new `db.set_audio_lang` / `db.set_version_audio_langs`, new `POST /api/videos/{id}/audio` handler (`api_choose_audio`), and per-version `audio_tracks` + row-level `audio_lang` in the serializer. Model, baseline migration, repository, schema, and videos-router tasks below include these.
- **New endpoints:** `POST /upload/file` (`upload_file` — direct file upload), `GET /assets/vendor/{filename}` (`vendor_asset`), `GET /assets/app/{filename}` (`app_asset`). Included in the videos/assets router tasks.
- **New modules not in the original plan:** `cache.py` (Redis cache used by `middleware.py` — **stays at root, it's infra not a domain service, middleware is out of scope**), `version_namer.py` (LLM version labeler, used by `library.py` — moves to `services/`), `relabel_versions.py` (standalone one-shot LLM migration script — **stays at root**, it is not imported by the app). New tests `tests/test_cache.py` and `tests/test_version_namer.py` move alongside their modules where applicable.

**Design doc:** `docs/superpowers/specs/2026-07-08-layered-architecture-refactor-design.md` — read it before starting; this plan implements it exactly. Locked decisions (SQLModel, Alembic with stamp-baseline, dedicated `repositories/`, model-instance row shape, sync engine, tests rewritten, pure-restructure scope) are not re-litigated here.

---

## Chunk 1: Foundations — models, database engine, Alembic baseline

**Files:**
- Modify: `requirements.txt`
- Create: `models/__init__.py`, `models/video.py`
- Create: `config.py`
- Create: `database.py`
- Create: `alembic.ini`, `alembic/env.py`, `alembic/script.py.mako`, `alembic/versions/0001_baseline.py`
- Test: `tests/test_models_video.py`

### Task 1.1: Add dependencies

- [ ] **Step 1:** Add to `requirements.txt` (keep alphabetical grouping as-is, append near the bottom):

```
alembic==1.13.3
SQLModel==0.0.22
```

- [ ] **Step 2:** Install into the existing venv:

```bash
python_env/bin/pip install alembic==1.13.3 SQLModel==0.0.22
```

Expected: installs cleanly (SQLModel pulls in `sqlalchemy>=2.0` and `pydantic`, already present transitively via FastAPI).

- [ ] **Step 3:** Commit

```bash
git add requirements.txt
git commit -m "deps: add SQLModel and Alembic"
```

### Task 1.2: `config.py` — CLASSIFICATIONS and shared settings

**Files:** Create `config.py`

- [ ] **Step 1:** Write `config.py`:

```python
import os
from pathlib import Path

CLASSIFICATIONS = ["children", "adults", "anabel", "tv", "movies"]

DB_PATH = os.getenv("DB_PATH", "data/watch_later.sqlite")
VIDEOS_DIR = Path("videos")
PREVIEWS_DIR = Path("data/previews")
SPLASH_DIR = Path("assets/splash")
```

Note: `db.py`'s `init_db()` uses `data/watch_later.db` as the `Path(...).parent.mkdir` default while `_conn()` uses `data/watch_later.sqlite` — a pre-existing mismatch. Per the design doc's non-goals, **preserve this exactly**: use `"data/watch_later.sqlite"` here (matches `_conn`, the value that actually matters for the live file), and keep the `.mkdir` call pointed at the same parent (`data/`) wherever it's ported in Chunk 1 Task 1.4 — same net effect, don't "fix" the naming.

- [ ] **Step 2:** No test needed (pure constants) — verified transitively by later chunks. Commit:

```bash
git add config.py
git commit -m "feat: add config module with CLASSIFICATIONS"
```

### Task 1.3: SQLModel models

**Files:** Create `models/__init__.py`, `models/video.py`. Test: `tests/test_models_video.py`

Reference schema: `db.py:42-128` (`init_db`) is the source of truth for every column.

- [ ] **Step 1:** Write the failing test `tests/test_models_video.py`:

```python
from sqlmodel import Session, SQLModel, create_engine, select

from models.video import Video, VideoVersion


def _engine():
    engine = create_engine("sqlite://")
    SQLModel.metadata.create_all(engine)
    return engine


def test_video_defaults():
    engine = _engine()
    with Session(engine) as session:
        video = Video(url="https://x.com/a/status/1", created_at="2026-07-08T00:00:00+00:00")
        session.add(video)
        session.commit()
        session.refresh(video)

        assert video.id == 1
        assert video.status == "queued"
        assert video.classification == "children"
        assert video.source == "download"
        assert video.hls_status == "none"
        assert video.versions == []


def test_video_version_relationship():
    engine = _engine()
    with Session(engine) as session:
        video = Video(
            url="/movies/a.mkv", source="library", source_path="/movies/a.mkv",
            created_at="2026-07-08T00:00:00+00:00",
        )
        session.add(video)
        session.commit()
        session.refresh(video)

        version = VideoVersion(video_id=video.id, source_path="/movies/a.mkv", label="Version 1")
        session.add(version)
        session.commit()
        session.refresh(video)

        assert [v.label for v in video.versions] == ["Version 1"]
        assert video.versions[0].status == "unconverted"


def test_unique_video_version_source_path():
    engine = _engine()
    with Session(engine) as session:
        video = Video(url="/movies/a.mkv", created_at="2026-07-08T00:00:00+00:00")
        session.add(video)
        session.commit()
        session.refresh(video)

        session.add(VideoVersion(video_id=video.id, source_path="/movies/a.mkv"))
        session.commit()
        session.add(VideoVersion(video_id=video.id, source_path="/movies/a.mkv"))
        import pytest
        from sqlalchemy.exc import IntegrityError
        with pytest.raises(IntegrityError):
            session.commit()
```

- [ ] **Step 2:** Run to verify it fails (module doesn't exist):

```bash
python_env/bin/python -m pytest tests/test_models_video.py -v
```

Expected: `ModuleNotFoundError: No module named 'models'`

- [ ] **Step 3:** Write `models/__init__.py` (empty) and `models/video.py`:

```python
from sqlmodel import Field, Relationship, SQLModel


class VideoVersion(SQLModel, table=True):
    __tablename__ = "video_versions"
    __table_args__ = ({"sqlite_autoincrement": True},)

    id: int | None = Field(default=None, primary_key=True)
    video_id: int = Field(foreign_key="videos.id", index=True)
    source_path: str
    label: str | None = None
    status: str = Field(default="unconverted")
    converted_path: str | None = None
    error_msg: str | None = None
    position: int = Field(default=0)
    created_at: str | None = None
    audio_langs: str | None = None       # JSON: source audio tracks (db.py:118)
    converted_langs: str | None = None   # JSON: langs kept in the conversion (db.py:120)

    video: "Video" = Relationship(back_populates="versions")


class Video(SQLModel, table=True):
    __tablename__ = "videos"

    id: int | None = Field(default=None, primary_key=True)
    url: str
    platform: str | None = None
    source_key: str | None = None
    title: str | None = None
    filename: str | None = None
    status: str = Field(default="queued")
    error_msg: str | None = None
    created_at: str
    preview_url: str | None = None
    position: int | None = None
    classification: str = Field(default="children")
    source: str = Field(default="download")
    source_path: str | None = Field(default=None, sa_column_kwargs={"unique": True})
    converted_path: str | None = None
    show_title: str | None = None
    season: int | None = None
    episode: int | None = None
    summary: str | None = None
    plex_rating_key: str | None = None
    show_rating_key: str | None = None
    deleted_at: str | None = None
    chosen_version_id: int | None = None
    hls_status: str = Field(default="none")
    audio_lang: str | None = None        # chosen audio language (db.py:96)

    versions: list[VideoVersion] = Relationship(back_populates="video")
```

Note: `source_path` is `UNIQUE` per `db.py:101-103` (`idx_videos_source_path`) — the `sa_column_kwargs={"unique": True}` reproduces that index.

- [ ] **Step 4:** Run to verify it passes:

```bash
python_env/bin/python -m pytest tests/test_models_video.py -v
```

Expected: 3 passed.

- [ ] **Step 5:** Commit

```bash
git add models/ tests/test_models_video.py
git commit -m "feat: add SQLModel Video and VideoVersion models"
```

### Task 1.4: `database.py` — engine, session factory, pragmas

**Files:** Create `database.py`. Test: `tests/test_database.py`

Reference: `db.py:9-16` (`_conn`) for the pragmas that must be preserved.

- [ ] **Step 1:** Write the failing test `tests/test_database.py`:

```python
from sqlalchemy import text

from database import get_engine, get_session


def test_engine_has_wal_and_busy_timeout(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.sqlite"))
    engine = get_engine()
    with engine.connect() as conn:
        mode = conn.execute(text("PRAGMA journal_mode")).scalar()
        timeout = conn.execute(text("PRAGMA busy_timeout")).scalar()
    assert mode == "wal"
    assert timeout == 30000


def test_get_session_yields_working_session(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.sqlite"))
    from sqlmodel import SQLModel
    engine = get_engine()
    SQLModel.metadata.create_all(engine)

    gen = get_session()
    session = next(gen)
    from models.video import Video
    session.add(Video(url="https://x.com/a/status/1", created_at="now"))
    session.commit()
    assert session.exec(__import__("sqlmodel").select(Video)).first().url == "https://x.com/a/status/1"
    gen.close()
```

- [ ] **Step 2:** Run to verify it fails:

```bash
python_env/bin/python -m pytest tests/test_database.py -v
```

Expected: `ModuleNotFoundError: No module named 'database'`

- [ ] **Step 3:** Write `database.py`:

```python
import os
from collections.abc import Iterator

from sqlalchemy import event
from sqlmodel import Session, create_engine

_engine = None
_engine_db_path = None


def get_engine():
    """Cache one engine per DB_PATH value; tests swap DB_PATH per-test via monkeypatch."""
    global _engine, _engine_db_path
    db_path = os.getenv("DB_PATH", "data/watch_later.sqlite")
    if _engine is None or _engine_db_path != db_path:
        _engine = create_engine(f"sqlite:///{db_path}", connect_args={"timeout": 30})

        @event.listens_for(_engine, "connect")
        def _set_pragmas(dbapi_connection, _record):
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.execute("PRAGMA busy_timeout=30000")
            cursor.close()

        _engine_db_path = db_path
    return _engine


def get_session() -> Iterator[Session]:
    with Session(get_engine()) as session:
        yield session
```

Note: `db.py`'s `_conn()` builds a brand-new `sqlite3.connect(...)` per call, so pragmas had to be set every call. SQLAlchemy's `connect` event does the same thing per-underlying-DBAPI-connection, so pooled connections all get WAL + busy_timeout — equivalent behavior.

- [ ] **Step 4:** Run to verify it passes:

```bash
python_env/bin/python -m pytest tests/test_database.py -v
```

Expected: 2 passed.

- [ ] **Step 5:** Commit

```bash
git add database.py tests/test_database.py
git commit -m "feat: add SQLModel engine/session factory with WAL pragmas"
```

### Task 1.5: Alembic baseline

**Files:** Create `alembic.ini`, `alembic/env.py`, `alembic/script.py.mako`, `alembic/versions/0001_baseline.py`

- [ ] **Step 1:** Scaffold Alembic:

```bash
cd /Users/grillermo/c/patatatube && python_env/bin/alembic init alembic
```

Expected: creates `alembic.ini` and `alembic/` with `env.py`, `script.py.mako`, `versions/`.

- [ ] **Step 2:** Edit `alembic.ini` — remove the hardcoded `sqlalchemy.url = driver://...` line (leave it blank/commented); the URL is supplied programmatically in `env.py` from `DB_PATH` so it always matches the app's env var, not a static config value.

- [ ] **Step 3:** Edit `alembic/env.py` — replace the `target_metadata = None` line and the URL wiring:

```python
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlmodel import SQLModel

import models.video  # noqa: F401  (registers tables on SQLModel.metadata)

target_metadata = SQLModel.metadata


def get_url() -> str:
    return f"sqlite:///{os.getenv('DB_PATH', 'data/watch_later.sqlite')}"
```

Then in both `run_migrations_offline()` and `run_migrations_online()`, replace `config.get_main_option("sqlalchemy.url")` with `get_url()`, and in `run_migrations_online()` replace the `engine_from_config(...)` block with:

```python
from sqlalchemy import create_engine
connectable = create_engine(get_url())
```

- [ ] **Step 4:** Author the baseline revision by hand (don't autogenerate against an empty DB — write it to match `db.py:31-108` exactly, including both indexes):

```bash
python_env/bin/alembic revision -m "baseline"
```

Edit the generated `alembic/versions/<hash>_baseline.py` (rename file to `0001_baseline.py` for clarity, keep the generated `revision` id string):

```python
"""baseline

Revision ID: 0001
Revises:
Create Date: 2026-07-08

"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "videos",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("url", sa.String, nullable=False),
        sa.Column("platform", sa.String),
        sa.Column("source_key", sa.String),
        sa.Column("title", sa.String),
        sa.Column("filename", sa.String),
        sa.Column("status", sa.String, nullable=False, server_default="queued"),
        sa.Column("error_msg", sa.String),
        sa.Column("created_at", sa.String, nullable=False),
        sa.Column("preview_url", sa.String),
        sa.Column("position", sa.Integer),
        sa.Column("classification", sa.String, nullable=False, server_default="children"),
        sa.Column("source", sa.String, nullable=False, server_default="download"),
        sa.Column("source_path", sa.String),
        sa.Column("converted_path", sa.String),
        sa.Column("show_title", sa.String),
        sa.Column("season", sa.Integer),
        sa.Column("episode", sa.Integer),
        sa.Column("summary", sa.String),
        sa.Column("plex_rating_key", sa.String),
        sa.Column("show_rating_key", sa.String),
        sa.Column("deleted_at", sa.String),
        sa.Column("chosen_version_id", sa.Integer),
        sa.Column("hls_status", sa.String, nullable=False, server_default="none"),
        sa.Column("audio_lang", sa.String),
    )
    op.create_index("idx_videos_source_path", "videos", ["source_path"], unique=True)

    op.create_table(
        "video_versions",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("video_id", sa.Integer, nullable=False),
        sa.Column("source_path", sa.String, nullable=False),
        sa.Column("label", sa.String),
        sa.Column("status", sa.String, nullable=False, server_default="unconverted"),
        sa.Column("converted_path", sa.String),
        sa.Column("error_msg", sa.String),
        sa.Column("position", sa.Integer, nullable=False, server_default="0"),
        sa.Column("created_at", sa.String, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("audio_langs", sa.String),
        sa.Column("converted_langs", sa.String),
        sa.UniqueConstraint("video_id", "source_path"),
    )
    op.create_index("idx_video_versions_video_id", "video_versions", ["video_id"])


def downgrade() -> None:
    op.drop_table("video_versions")
    op.drop_table("videos")
```

- [ ] **Step 5:** Verify the baseline against a throwaway fresh DB:

```bash
rm -f /tmp/baseline_check.sqlite
DB_PATH=/tmp/baseline_check.sqlite python_env/bin/alembic upgrade head
python_env/bin/python -c "
import sqlite3
conn = sqlite3.connect('/tmp/baseline_check.sqlite')
cols = {r[1] for r in conn.execute('PRAGMA table_info(videos)')}
assert 'hls_status' in cols and 'chosen_version_id' in cols and 'audio_lang' in cols, cols
print('OK', sorted(cols))
"
rm -f /tmp/baseline_check.sqlite
```

Expected: prints `OK [...]` listing all 24 `videos` columns.

- [ ] **Step 6:** Stamp the **real** dev/prod DB (do this once, manually, against `data/watch_later.sqlite` — never re-run `upgrade head` against it):

```bash
DB_PATH=data/watch_later.sqlite python_env/bin/alembic stamp 0001
```

Expected: no schema changes to `data/watch_later.sqlite`, just an `alembic_version` table recording `0001`. **Confirm this file already has both tables with all current columns before stamping** — if any column present in the live DB is missing from the baseline `upgrade()`, add it and re-verify Step 5 before stamping the real file.

- [ ] **Step 7:** Commit

```bash
git add alembic.ini alembic/
git commit -m "feat: add Alembic with schema baseline"
```

---

## Chunk 2: Repositories

**Files:**
- Create: `repositories/__init__.py`, `repositories/videos.py`
- Test: `tests/test_repositories_videos.py` (replaces `tests/test_db.py`)

This chunk ports every function in `db.py` (lines ~243–810; skip `init_db`/backfills/`_conn`/`_add_column`, which move in Chunk 5) to operate on a SQLModel `Session` and return model instances instead of dicts. Read `db.py` fully before starting — the version-sync logic (`_ensure_chosen_version`, `_sync_video_from_chosen`, `_sync_versions`) is the highest-risk part of this whole refactor and must be ported with identical semantics.

### Function mapping

Line numbers below are approximate — the file has drifted; grep for the `def` name.

| `db.py` function | new `repositories/videos.py` function | notes |
|---|---|---|
| `add_video` (243) | `add_video(session, url, *, platform=None, source_key=None, title=None, preview_url=None) -> Video` | returns the model, not an int id |
| `get_video` (454) | `get_video(session, video_id) -> Video \| None` | attaches `versions` for library rows (`_video_with_versions`, db.py:270) |
| `get_all_videos` (466) | `get_all_videos(session, classification=None) -> list[Video]` | attaches versions via `_attach_versions` (db.py:483) |
| `delete_video` (460) | `delete_video(session, video_id) -> None` | cascade-delete versions |
| `update_video` (543) | `update_video(session, video_id, status, *, filename=None, error_msg=None, title=None, preview_url=None) -> None` | status == "error" still deletes the row |
| `get_completed_video_by_source` (529) | same name | |
| `set_video_classification` (518) | same name | |
| `set_hls_status` (523) | same name | |
| `set_audio_lang` (441) | same name | writes `videos.audio_lang` |
| `set_version_audio_langs` (446) | same name | writes `video_versions.audio_langs` (JSON) |
| `youtube_preview_url` (570) | same name -> `str \| None` | pure function, no session |
| `get_video_versions` (300) | same name -> `list[VideoVersion]` | |
| `get_video_version` (326) | same name -> `VideoVersion \| None` | sets `.is_chosen` — see note below |
| `set_chosen_version` (412) | same name -> `bool` | |
| `get_version_labels` (305) | same name -> `dict[str, str]` | |
| `upsert_library_video` (658) | same name -> `tuple[int, str]` | |
| `tombstone_video` (749) | same name | |
| `get_converted_paths` (757) | same name -> `set[str]` | |
| `set_library_state` (774) | same name | |
| `_ensure_chosen_version` (373) | `_ensure_chosen_version(session, video_id) -> int \| None` | private helper, same file |
| `_sync_video_from_chosen` (348) | `_sync_video_from_chosen(session, video_id) -> None` | private helper |
| `_sync_versions` (613) | `_sync_versions(session, video_id, item) -> None` | private helper |
| `_incoming_versions` (598) | `_incoming_versions(item) -> list[dict]` | pure function, no session |
| `_video_with_versions` (270), `_get_video_versions` (279), `_attach_versions` (483) | private helpers | fold into the repo (used by `get_video`/`get_all_videos`) |

**Note — `move_video` is gone:** manual reorder was removed from the app. Do not port `move_video`, and do not add an `apply_move`/`api_move_video`/move route anywhere in this refactor.

**`is_chosen` note:** today `get_video_version`/`_get_video_versions` set `version["is_chosen"] = ...` on the dict. `VideoVersion` is a persisted SQLModel — do **not** persist a transient `is_chosen` flag on it. Set it as a plain Python attribute after fetch (SQLModel instances allow arbitrary attribute assignment even though it's not a mapped column): `version.is_chosen = ...`. This is a stopgap only inside the repository layer for `get_video_version`/`get_video_versions`, matching current behavior; Chunk 3's `VideoOut` schema recomputes `is_chosen` independently from `chosen_version_id` and does not rely on this attribute, per the design doc.

### Task 2.1: Simple CRUD (worked example — do this one fully, then repeat the pattern)

**Files:** Create `repositories/__init__.py` (empty), start `repositories/videos.py`. Test: `tests/test_repositories_videos.py`

- [ ] **Step 1:** Write the failing test (first slice — `add_video` and `get_video`):

```python
from sqlmodel import Session, SQLModel, create_engine

import repositories.videos as repo


def _session():
    engine = create_engine("sqlite://")
    SQLModel.metadata.create_all(engine)
    return Session(engine)


def test_add_and_get_video():
    session = _session()
    video = repo.add_video(session, "https://twitter.com/x/status/123")
    assert video.id == 1
    assert video.position == 1

    fetched = repo.get_video(session, video.id)
    assert fetched.url == "https://twitter.com/x/status/123"
    assert fetched.status == "queued"


def test_get_video_missing_returns_none():
    session = _session()
    assert repo.get_video(session, 999) is None
```

- [ ] **Step 2:** Run, verify fails: `python_env/bin/python -m pytest tests/test_repositories_videos.py -v` → `ModuleNotFoundError`.

- [ ] **Step 3:** Write `repositories/videos.py` (first slice):

```python
from datetime import datetime, timezone

from sqlmodel import Session, func, select

from models.video import Video, VideoVersion


def add_video(
    session: Session,
    url: str,
    *,
    platform: str | None = None,
    source_key: str | None = None,
    title: str | None = None,
    preview_url: str | None = None,
) -> Video:
    next_position = (session.exec(select(func.max(Video.position))).first() or 0) + 1
    video = Video(
        url=url,
        platform=platform,
        source_key=source_key,
        title=title,
        preview_url=preview_url,
        created_at=datetime.now(timezone.utc).isoformat(),
        position=next_position,
    )
    session.add(video)
    session.commit()
    session.refresh(video)
    return video


def get_video(session: Session, video_id: int) -> Video | None:
    return session.get(Video, video_id)
```

- [ ] **Step 4:** Run, verify passes.

- [ ] **Step 5:** Commit

```bash
git add repositories/ tests/test_repositories_videos.py
git commit -m "feat: start repositories.videos with add_video/get_video"
```

### Task 2.2: `get_all_videos`, `delete_video`, `update_video`

**Files:** Modify `repositories/videos.py`, `tests/test_repositories_videos.py`

Port `db.py:409-433` and `492-516`. `get_all_videos` ordering (`position DESC, created_at DESC`) and the classification filter must match exactly. `update_video` with `status="error"` still deletes the row (`db.py:500-502`) — preserve that, it's load-bearing per `CLAUDE.md` ("Failures don't get an `error` status ... the download exception handler both delete the row").

- [ ] **Step 1:** Write failing tests:

```python
def test_get_all_videos_orders_by_position_desc_then_created_at_desc():
    session = _session()
    v1 = repo.add_video(session, "https://x.com/a/status/1")
    v2 = repo.add_video(session, "https://x.com/a/status/2")
    videos = repo.get_all_videos(session)
    assert [v.id for v in videos] == [v2.id, v1.id]


def test_get_all_videos_filters_by_classification():
    session = _session()
    v1 = repo.add_video(session, "https://x.com/a/status/1")
    v1.classification = "tv"
    session.add(v1)
    session.commit()
    repo.add_video(session, "https://x.com/a/status/2")

    videos = repo.get_all_videos(session, classification="tv")
    assert [v.id for v in videos] == [v1.id]


def test_delete_video_removes_row_and_versions():
    session = _session()
    video = repo.add_video(session, "https://x.com/a/status/1")
    session.add(VideoVersion(video_id=video.id, source_path="/a.mkv"))
    session.commit()

    repo.delete_video(session, video.id)
    assert repo.get_video(session, video.id) is None
    from sqlmodel import select
    assert session.exec(select(VideoVersion).where(VideoVersion.video_id == video.id)).first() is None


def test_update_video_done_sets_filename_and_status():
    session = _session()
    video = repo.add_video(session, "https://x.com/a/status/1")
    repo.update_video(session, video.id, status="done", filename="1.mp4", title="Hi")
    fetched = repo.get_video(session, video.id)
    assert fetched.status == "done"
    assert fetched.filename == "1.mp4"
    assert fetched.title == "Hi"


def test_update_video_error_deletes_row():
    session = _session()
    video = repo.add_video(session, "https://x.com/a/status/1")
    repo.update_video(session, video.id, status="error")
    assert repo.get_video(session, video.id) is None
```

(Add `from models.video import VideoVersion` to the test file's imports.)

- [ ] **Step 2:** Run, verify fails.

- [ ] **Step 3:** Append to `repositories/videos.py`:

```python
def get_all_videos(session: Session, classification: str | None = None) -> list[Video]:
    statement = select(Video).where(Video.deleted_at.is_(None))
    if classification:
        statement = statement.where(Video.classification == classification)
    statement = statement.order_by(Video.position.desc(), Video.created_at.desc())
    return list(session.exec(statement).all())


def delete_video(session: Session, video_id: int) -> None:
    session.exec(select(VideoVersion).where(VideoVersion.video_id == video_id)).all()
    for version in session.exec(select(VideoVersion).where(VideoVersion.video_id == video_id)).all():
        session.delete(version)
    video = session.get(Video, video_id)
    if video:
        session.delete(video)
    session.commit()


def update_video(
    session: Session,
    video_id: int,
    status: str,
    *,
    filename: str | None = None,
    error_msg: str | None = None,
    title: str | None = None,
    preview_url: str | None = None,
) -> None:
    if status == "error":
        delete_video(session, video_id)
        return

    video = session.get(Video, video_id)
    if not video:
        return
    video.status = status
    video.filename = filename if filename is not None else video.filename
    video.error_msg = error_msg
    video.title = title if title is not None else video.title
    video.preview_url = preview_url if preview_url is not None else video.preview_url
    session.add(video)
    session.commit()
```

Note the redundant `session.exec(...).all()` line before the loop in `delete_video` above is a mistake — remove it, it's dead code. (Left in the plan text as a reminder to review generated code before committing; the loop already fetches what it needs.)

- [ ] **Step 4:** Run, verify passes.

- [ ] **Step 5:** Commit

```bash
git add repositories/videos.py tests/test_repositories_videos.py
git commit -m "feat: repositories.videos get_all_videos/delete_video/update_video"
```

### Task 2.3: `get_completed_video_by_source`, `set_video_classification`, `set_hls_status`, `set_audio_lang`, `set_version_audio_langs`

Port `db.py:518-540` (`set_video_classification`, `set_hls_status`), `529-540` (`get_completed_video_by_source`), and `441-451` (`set_audio_lang`, `set_version_audio_langs`). Straightforward single/double-statement functions — same TDD loop as Task 2.2 (write tests mirroring the corresponding cases in `tests/test_db.py`, port the function body verbatim adapted to `select`/`session.get`, run, commit).

(`move_video` used to live here — it was deleted from the app along with manual reorder, so there is nothing to port.)

- [ ] Commit message when done: `"feat: repositories.videos classification/hls_status/audio_lang"`

### Task 2.4: Version-sync logic — the hard part

**Files:** Modify `repositories/videos.py`, `tests/test_repositories_videos.py`

Port `db.py:280-406` (`get_video_versions`, `get_video_version`, `set_chosen_version`, `_ensure_chosen_version`, `_sync_video_from_chosen`) and `547-604` (`_incoming_versions`, `_sync_versions`). Read `db.py:328-406` twice before writing code — `_ensure_chosen_version` both reads and repairs `chosen_version_id`, and `_sync_video_from_chosen` denormalizes the chosen version's fields back onto the parent `Video` row so `/stream` and the serializer can read `video.status`/`video.source_path` directly without a join. Losing that denormalization silently breaks streaming for library videos.

- [ ] **Step 1:** Port the existing `tests/test_db.py` cases for these functions (search for `chosen_version`, `_sync_versions`, `set_chosen_version`, `get_video_version` in `tests/test_db.py` and translate each to the new API — same inputs/assertions, `db.xxx(...)` becomes `repo.xxx(session, ...)`).

- [ ] **Step 2:** Run, verify fails.

- [ ] **Step 3:** Port the five functions with the same control flow as `db.py:280-406`, operating on `session.get`/`select` instead of raw SQL, setting `video.chosen_version_id` and denormalized fields as attribute assignments + `session.commit()` in place of `UPDATE` statements.

- [ ] **Step 4:** Run, verify passes.

- [ ] **Step 5:** Commit: `"feat: repositories.videos version-sync (chosen version, versions sync)"`

### Task 2.5: Library upsert + remaining functions

**Files:** Modify `repositories/videos.py`, `tests/test_repositories_videos.py`

Port `db.py:607-698` (`upsert_library_video`, `tombstone_video`), `701-715` (`get_converted_paths`), `718-762` (`set_library_state`), and `get_version_labels` (`db.py:285-303`). Same TDD loop, porting the corresponding `tests/test_db.py` cases (search for `upsert_library_video`, `tombstone`, `get_converted_paths`, `set_library_state`).

- [ ] Commit message: `"feat: repositories.videos library upsert/tombstone/state"`

### Task 2.6: Retire `tests/test_db.py`

- [ ] **Step 1:** Diff `tests/test_db.py` against `tests/test_repositories_videos.py` function-by-function; confirm every test case has an equivalent (same assertions, translated API).
- [ ] **Step 2:** `git rm tests/test_db.py`
- [ ] **Step 3:** Run full repo test suite to confirm nothing regressed: `python_env/bin/python -m pytest tests/ -q`
- [ ] **Step 4:** Commit: `"test: remove tests/test_db.py, superseded by test_repositories_videos.py"`

---

## Chunk 3: Schemas

**Files:**
- Create: `schemas/__init__.py`, `schemas/videos.py`
- Test: `tests/test_schemas_videos.py` (replaces `tests/test_serializers.py`)

### Task 3.1: Request schemas

**Files:** Create `schemas/videos.py`

- [ ] **Step 1:** No test needed — these are pure `BaseModel` field declarations, ported verbatim from `router.py`'s `UploadRequest`/`ClassifyRequest`/`VersionRequest` (currently near `router.py:102-112`). There is **no `MoveRequest`** (reorder was removed). If `api_choose_audio` uses a request body, port that model too (check `router.py:653`; it may take a form/query param rather than a body). Write:

```python
from pydantic import BaseModel


class UploadRequest(BaseModel):
    url: str


class ClassifyRequest(BaseModel):
    classification: str


class VersionRequest(BaseModel):
    version_id: int
```

- [ ] **Step 2:** Commit: `"feat: add schemas.videos request models"`

### Task 3.2: `VideoOut` response schema

**Files:** Modify `schemas/videos.py`. Test: `tests/test_schemas_videos.py`

Port `views/serializers.py` exactly (`_audio_tracks` + `_hls_ready` + `preview_url_for` + `serialize_video`), but operating on a `Video`/`VideoVersion` model instance instead of a dict, and computing `is_chosen` from `video.chosen_version_id` rather than a stored/attached key (per design doc §schemas/).

**The serializer has grown since this plan was written — port all of it:**
- `_audio_tracks(version)` — decodes `version.audio_langs` / `version.converted_langs` (JSON), intersects with `library.allowed_audio_langs()`, and marks each track `available`. Emits per-version `audio_tracks`.
- Library rows also emit `audio_lang` (the row-level chosen language) and `source_filename` (basename of the raw `url`/source_path — the client searches by filename without leaking the server's directory layout).
- `platform == "upload"` rows redact `url` to `""` just like library rows (the `url` temporarily holds the local upload path).
- `preview_url_for` is the poster-URL helper (library → `/videos/{id}/preview`, download → `preview_url` column).

Read the current `views/serializers.py` top-to-bottom before porting — the code sketch below is illustrative, not exhaustive.

- [ ] **Step 1:** Write the failing test — port every case in `tests/test_serializers.py` to build `Video`/`VideoVersion` model instances instead of dicts:

```python
from models.video import Video, VideoVersion
from schemas.videos import VideoOut


def test_video_out_full_shape():
    video = Video(
        id=7,
        url="https://youtu.be/dQw4w9WgXcQ",
        title="A Song",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        classification="children",
        position=3,
        status="done",
        filename="7.mp4",
        created_at="2026-07-02T00:00:00+00:00",
    )
    out = VideoOut.from_model(video)
    assert out == {
        "id": 7,
        "url": "https://youtu.be/dQw4w9WgXcQ",
        "title": "A Song",
        "platform": "youtube",
        "source_key": "dQw4w9WgXcQ",
        "preview_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "classification": "children",
        "position": 3,
        "status": "done",
        "error_msg": None,
        "stream_path": "/videos/7/stream",
        "source": "download",
        "show_title": None,
        "season": None,
        "episode": None,
        "summary": None,
        "show_preview_url": None,
        "subtitle_tracks": [],
        "hls_path": "/videos/7/hls/master.m3u8",
    }


def test_video_out_library_redacts_url_and_computes_is_chosen():
    video = Video(
        id=9, url="/movies/a.mkv", source="library", status="unconverted",
        created_at="2026-07-02T00:00:00+00:00", chosen_version_id=101,
    )
    v1 = VideoVersion(id=101, video_id=9, source_path="/movies/a.mkv", label="1080p", status="done")
    v2 = VideoVersion(id=102, video_id=9, source_path="/movies/a-4k.mkv", label="4K", status="unconverted")
    video.versions = [v1, v2]

    out = VideoOut.from_model(video)
    assert out["url"] == ""
    assert out["preview_url"] == "/videos/9/preview"
    assert out["source_filename"] == "a.mkv"
    assert out["chosen_version_id"] == 101
    assert out["audio_lang"] is None
    assert out["versions"] == [
        {"id": 101, "label": "1080p", "status": "done", "is_chosen": True, "audio_tracks": []},
        {"id": 102, "label": "4K", "status": "unconverted", "is_chosen": False, "audio_tracks": []},
    ]
    assert out["hls_path"] == "/videos/9/hls/master.m3u8"  # a version is done


def test_video_out_accepts_injected_subtitle_tracks():
    video = Video(id=1, url="/a.mkv", source="library", status="unconverted", created_at="now")
    out = VideoOut.from_model(video, subtitle_tracks=[{"language": "en", "name": "English", "default": True, "forced": False}])
    assert out["subtitle_tracks"] == [{"language": "en", "name": "English", "default": True, "forced": False}]
```

Port the remaining `test_serializers.py` cases (show_preview_url for `show_rating_key`, hls-not-ready omits `hls_path`, etc.) the same way.

- [ ] **Step 2:** Run, verify fails.

- [ ] **Step 3:** Write `VideoOut` in `schemas/videos.py`:

```python
import json

from library import allowed_audio_langs
from models.video import Video, VideoVersion


def _audio_tracks(version: VideoVersion) -> list[dict]:
    try:
        source_tracks = json.loads(version.audio_langs or "[]")
    except (TypeError, ValueError):
        return []
    converted = None
    if version.converted_langs:
        try:
            converted = json.loads(version.converted_langs)
        except (TypeError, ValueError):
            converted = None
    allowed = allowed_audio_langs()
    first_lang = source_tracks[0]["lang"] if source_tracks else None
    tracks, seen = [], set()
    for track in source_tracks:
        lang = track.get("lang")
        if lang not in allowed or lang in seen:
            continue
        seen.add(lang)
        available = lang in converted if converted is not None else lang == first_lang
        tracks.append({"lang": lang, "title": track.get("title") or "", "available": available})
    return tracks


def _hls_ready(video: Video) -> bool:
    if video.source == "library":
        return any(v.status == "done" for v in video.versions) or bool(video.converted_path)
    return video.status == "done"


class VideoOut:
    @staticmethod
    def from_model(video: Video, *, subtitle_tracks: list[dict] | None = None) -> dict:
        data = {
            "id": video.id,
            "url": video.url,
            "title": video.title,
            "platform": video.platform,
            "source_key": video.source_key,
            "preview_url": video.preview_url,
            "classification": video.classification or "children",
            "position": video.position,
            "status": video.status,
            "error_msg": video.error_msg,
            "stream_path": f"/videos/{video.id}/stream",
            "source": video.source,
            "show_title": video.show_title,
            "season": video.season,
            "episode": video.episode,
            "summary": video.summary,
            "show_preview_url": None,
            "subtitle_tracks": subtitle_tracks or [],
        }
        if _hls_ready(video):
            data["hls_path"] = f"/videos/{video.id}/hls/master.m3u8"
        if video.source == "library":
            data["chosen_version_id"] = video.chosen_version_id
            data["audio_lang"] = video.audio_lang
            data["versions"] = [
                {
                    "id": v.id,
                    "label": v.label,
                    "status": v.status,
                    "is_chosen": v.id == video.chosen_version_id,
                    "audio_tracks": _audio_tracks(v),
                }
                for v in video.versions
            ]
            data["preview_url"] = f"/videos/{video.id}/preview"
            raw_path = video.url or ""
            data["source_filename"] = raw_path.rsplit("/", 1)[-1] or None
            data["url"] = ""
            if video.show_rating_key:
                data["show_preview_url"] = f"/videos/{video.id}/preview?kind=show"
        if video.platform == "upload":
            data["url"] = ""
        return data
```

Note the behavior difference from `serialize_video`: the old code only added `"versions"`/`"chosen_version_id"`/`"audio_lang"` keys `if video.get("versions") is not None` — i.e. only when the caller (repository's `_video_with_versions`/`_attach_versions`) had attached a `versions` list, which it only did for `source == "library"` rows. Here, gating directly on `video.source == "library"` is equivalent because those helpers used exactly that same condition. Confirm this equivalence is exercised by a download-row test case (no `versions`/`chosen_version_id`/`audio_lang` keys present) alongside the library-row case above, and add a `platform == "upload"` case asserting `url == ""`.

- [ ] **Step 4:** Run, verify passes.

- [ ] **Step 5:** Commit: `"feat: add schemas.videos.VideoOut replacing serialize_video"`

### Task 3.3: Retire `views/serializers.py` and `tests/test_serializers.py`

- [ ] **Step 1:** `git rm views/serializers.py tests/test_serializers.py`
- [ ] **Step 2:** `grep -rn "views.serializers\|serialize_video" --include=*.py .` — confirm no remaining references (Chunk 5 will have already repointed `router.py`'s two call sites; if this chunk runs first, leave those call sites broken until Chunk 5, or reorder to do Chunk 5's videos-router task alongside this cleanup — prefer finishing Chunk 5 first and coming back to delete these files as part of Chunk 5's cleanup task instead of here, to avoid a broken intermediate commit).
- [ ] **Step 3:** Commit only once `main.py`/routers no longer import `views.serializers` (see Chunk 5 Task 5.6).

---

## Chunk 4: Services

**Files:**
- Create: `services/__init__.py`, `services/videos.py`, `services/url_classifier.py`
- Move: `downloader.py` → `services/downloader.py`, `library.py` → `services/library.py`, `hls.py` → `services/hls.py`, `subtitles.py` → `services/subtitles.py`, `plex.py` → `services/plex.py`
- Move tests: `tests/test_downloader.py` → `tests/test_services_downloader.py` (etc. for library/hls/plex/subtitles)

### Task 4.1: `services/url_classifier.py`

Port `_normalize_twitter_url`, `_extract_youtube_id`, `_normalize_youtube_url`, `_youtube_preview_url`, `_classify_url`, and `YOUTUBE_ID_RE` from `router.py` (currently `router.py:56, 106-186`) verbatim — pure functions, no DB/session dependency.

- [ ] **Step 1:** Write failing tests in `tests/test_services_url_classifier.py`, porting the relevant cases from `tests/test_api.py`'s `test_upload_rejects_invalid_or_unsupported_urls` and the youtube-strips-query-params test — call `url_classifier._classify_url(...)` directly instead of going through `/upload`.
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Create `services/url_classifier.py` with the ported functions (identical bodies, `HTTPException` import stays since `_classify_url` raises it on invalid input — matches current behavior).
- [ ] **Step 4:** Run, verify passes.
- [ ] **Step 5:** Commit: `"feat: add services.url_classifier"`

### Task 4.2: `services/videos.py`

Port today's `services.py` (`apply_classification`, `choose_version` — note **there is no `apply_move`**, reorder was removed) plus the delete/prepare/audio orchestration currently inline in `router.py`'s `api_delete_video` (`router.py:689`), `api_prepare_video` (`router.py:745`), and `api_choose_audio` (`router.py:653`), converting `db.xxx(...)` calls to `repositories.videos.xxx(session, ...)`.

`choose_version` must keep calling `hls.invalidate(video_id)` after a successful `set_chosen_version` (today's `services.py:16` — the chosen version changed, so the cached HLS package is stale). Preserve that; the plan's original sketch dropped it.

- [ ] **Step 1:** Write failing tests in `tests/test_services_videos.py`, porting `tests/test_services.py` cases (`fresh_db` fixture becomes a fixture that builds an in-memory `Session` per Chunk 2's pattern) plus new tests for `delete_video_and_files`, `prepare_video`, and audio selection covering the branches currently in `router.py`'s delete/prepare/audio handlers (library file cleanup, download-row deletion, "not found", "not library", "already done", "already converting", passthrough-done, queues background conversion, audio-lang change invalidates HLS).
- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Write `services/videos.py`:

```python
from pathlib import Path

from sqlmodel import Session

import repositories.videos as repo
import services.hls as hls
from config import CLASSIFICATIONS, VIDEOS_DIR


def apply_classification(session: Session, video_id: int, classification: str) -> bool:
    if classification not in CLASSIFICATIONS:
        return False
    repo.set_video_classification(session, video_id, classification)
    return True


def choose_version(session: Session, video_id: int, version_id: int) -> bool:
    chosen = repo.set_chosen_version(session, video_id, version_id)
    if chosen:
        hls.invalidate(video_id)  # chosen version changed → cached HLS is stale
    return chosen


def delete_video_and_files(session: Session, video_id: int) -> None:
    video = repo.get_video(session, video_id)
    if not video:
        return
    if video.source == "library":
        for version in video.versions:
            if version.converted_path:
                Path(version.converted_path).unlink(missing_ok=True)
        if video.converted_path:
            Path(video.converted_path).unlink(missing_ok=True)
        repo.tombstone_video(session, video_id)
    else:
        if video.filename:
            (VIDEOS_DIR / video.filename).unlink(missing_ok=True)
        repo.delete_video(session, video_id)
```

`prepare_video`'s orchestration (probe → plan → passthrough-done or queue background conversion) stays a thin wrapper here that the `api/v1/videos.py` router calls, keeping the `HTTPException`-raising / status-code decisions in the router (that's presentation concern) and the DB-state transitions here. Port the exact branching from `router.py`'s `api_prepare_video` when writing this function, preserving the "write converting before the first await" comment and race-window rationale verbatim (it documents real behavior, not filler).

- [ ] **Step 4:** Run, verify passes.
- [ ] **Step 5:** Commit: `"feat: add services.videos (move/classify/choose/delete/prepare)"`

### Task 4.3: Move `downloader.py`, `library.py`, `hls.py`, `subtitles.py`, `plex.py`, `version_namer.py`

`version_namer.py` (LLM version labeler, imported by `library.py`) moves to `services/` too. **`cache.py` stays at root** — it's the Redis cache consumed by `middleware.py`, which is out of scope for this refactor. **`relabel_versions.py` stays at root** — it's a standalone one-shot migration script, not imported by the app.

Each moved module needs only import-path updates (`import db` → `import repositories.videos as repo` + a `Session`), not logic changes, **except** every call site that currently does `db.get_video(id)` / `db.update_video(...)` etc. needs a `Session`. Since these run as FastAPI background tasks (outside request scope), each top-level entry point (`download_video`, `convert_library_video`, `scan_library`, `hls.prepare`) opens its own session via `database.get_session()`'s underlying engine, e.g.:

```python
from sqlmodel import Session
from database import get_engine

def download_video(video_id: int):
    with Session(get_engine()) as session:
        ...
```

- [ ] **Step 1:** `git mv downloader.py services/downloader.py`, `git mv library.py services/library.py`, `git mv hls.py services/hls.py`, `git mv subtitles.py services/subtitles.py`, `git mv plex.py services/plex.py`, `git mv version_namer.py services/version_namer.py`
- [ ] **Step 2:** `git mv tests/test_downloader.py tests/test_services_downloader.py` (repeat for library/hls/plex/subtitles/version_namer)
- [ ] **Step 3:** For each moved service module, update its `import db` (only `downloader.py` and `library.py` import it) to open a `Session` per top-level function as shown above, and replace each `db.xxx(...)` call with `repo.xxx(session, ...)` — following the same pattern as Chunk 2/4.2. Update the corresponding test file's fixtures (`downloader_env` in `test_services_downloader.py` etc.) to build a `Session`/temp DB via Chunk 2's `_session()` helper instead of `importlib.reload(db)`.
- [ ] **Step 4:** Update the intra-service imports that changed path: `library.py`'s `from downloader import _probe_media` → `from services.downloader import _probe_media`, `library.py`'s import of `version_namer` → `from services import version_namer` (or `services.version_namer`); anything importing `hls`/`subtitles`/`plex` at their old top-level path needs `services.` prefix. **Also `schemas/videos.py` (Chunk 3) imports `from library import allowed_audio_langs`** — repoint it to `from services.library import allowed_audio_langs` when `library.py` moves here (or leave a compat shim until this task lands; note the cross-chunk dependency).
- [ ] **Step 5:** Run each test file individually as it's fixed:

```bash
python_env/bin/python -m pytest tests/test_services_downloader.py tests/test_services_library.py tests/test_services_hls.py tests/test_services_plex.py tests/test_services_subtitles.py -v
```

Expected: all passing, one file worked through at a time (commit after each file, not as one giant batch).

- [ ] **Step 6:** Commit per file, e.g.: `"refactor: move downloader.py to services/, thread Session through"`

---

## Chunk 5: API layer

**Files:**
- Create: `api/__init__.py`, `api/dependencies.py`, `api/v1/__init__.py`, `api/v1/videos.py`, `api/v1/library.py`, `api/v1/streaming.py`, `api/v1/pages.py`, `api/v1/assets.py`
- Modify: `main.py`
- Delete: `router.py`, `services.py`, `db.py` (old top-level), `views/serializers.py` (if not already removed in Chunk 3)
- Test: rewrite `tests/test_api.py`'s fixtures; individual test bodies mostly unchanged (they hit HTTP endpoints, not internals) except monkeypatch targets

This is the highest-line-count chunk but the lowest-risk one — it's wiring, not new logic. Each router file is route handlers copied from `router.py` with three substitutions: (1) `db.xxx(...)` → `repo.xxx(session, ...)` with a `session: Session = Depends(get_session)` parameter added to the handler, (2) `services.xxx(...)` → `services.videos.xxx(session, ...)`, (3) `serialize_video(v)` → `VideoOut.from_model(v)`.

### Task 5.1: `api/dependencies.py`

Port `_check_token`/`_check_token_or_query` (`router.py:59-77`) as dependency functions, plus `get_session` re-exported from `database.py` for convenient single-import in routers.

- [ ] **Step 1:** Write failing tests `tests/test_api_dependencies.py`:

```python
import pytest
from fastapi import HTTPException, Request

from api.dependencies import require_token, require_token_or_query


def _request(headers=None, query=""):
    scope = {
        "type": "http", "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
        "query_string": query.encode(),
    }
    return Request(scope)


def test_require_token_missing_env_is_503(monkeypatch):
    monkeypatch.delenv("UPLOAD_TOKEN", raising=False)
    with pytest.raises(HTTPException) as exc:
        require_token(_request())
    assert exc.value.status_code == 503


def test_require_token_rejects_wrong_bearer(monkeypatch):
    monkeypatch.setenv("UPLOAD_TOKEN", "secret")
    with pytest.raises(HTTPException) as exc:
        require_token(_request({"Authorization": "Bearer wrong"}))
    assert exc.value.status_code == 401


def test_require_token_accepts_correct_bearer(monkeypatch):
    monkeypatch.setenv("UPLOAD_TOKEN", "secret")
    require_token(_request({"Authorization": "Bearer secret"}))  # no raise


def test_require_token_or_query_accepts_query_param(monkeypatch):
    monkeypatch.setenv("UPLOAD_TOKEN", "secret")
    require_token_or_query(_request(query="token=secret"))  # no raise
```

- [ ] **Step 2:** Run, verify fails.
- [ ] **Step 3:** Write `api/dependencies.py`:

```python
import os
import secrets

from fastapi import HTTPException, Request

from database import get_session  # re-exported for single-import convenience

__all__ = ["get_session", "require_token", "require_token_or_query"]


def require_token(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or not secrets.compare_digest(auth[7:], token):
        raise HTTPException(status_code=401, detail="Unauthorized")


def require_token_or_query(request: Request):
    token = os.getenv("UPLOAD_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Upload not configured")
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer ") and secrets.compare_digest(auth[7:], token):
        return
    query_token = request.query_params.get("token", "")
    if query_token and secrets.compare_digest(query_token, token):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")
```

- [ ] **Step 4:** Run, verify passes.
- [ ] **Step 5:** Commit: `"feat: add api.dependencies (token guards, get_session re-export)"`

### Task 5.2: `api/v1/videos.py`

Port from `router.py`: `UploadRequest`/`ClassifyRequest`/`VersionRequest` usage (import from `schemas.videos` now — **no `MoveRequest`**), `check_auth`, `upload`, `upload_file` (the `POST /upload/file` direct-upload handler), `api_classifications`, `api_videos`, `api_classify_video`, `api_choose_video_version`, `api_choose_audio` (`POST /api/videos/{id}/audio`), `api_delete_video`, `api_video`, `api_prepare_video`, `_print_bad_request_details`. **Do not port `api_move_video`** (removed). `_guess_mime` is only used by streaming — leave it in `api/v1/streaming.py`, not here.

- [ ] **Step 1:** Write/port failing tests: split `tests/test_api.py`'s upload/upload-file/classify/version/audio/delete/prepare/detail test functions into `tests/test_api_videos.py` (mechanical move, same bodies) with a shared `client` fixture (see Task 5.7).
- [ ] **Step 2:** Run, verify fails (endpoints don't exist yet on the new router).
- [ ] **Step 3:** Write `api/v1/videos.py`, e.g. for `upload` and `api_videos`:

```python
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from sqlmodel import Session

import repositories.videos as repo
import services.videos as video_service
from api.dependencies import get_session, require_token
from config import CLASSIFICATIONS
from schemas.videos import ClassifyRequest, UploadRequest, VersionRequest, VideoOut
from services.downloader import download_video
from services.url_classifier import _classify_url, _youtube_preview_url

router = APIRouter()


def _print_bad_request_details(request: Request, body: UploadRequest):
    print("400 Bad Request details:", flush=True)
    print(f"  method={request.method}", flush=True)
    print(f"  url={request.url}", flush=True)
    print(f"  path_params={dict(request.path_params)}", flush=True)
    print(f"  query_params={dict(request.query_params)}", flush=True)
    print(f"  headers={dict(request.headers)}", flush=True)
    print(f"  body={body.model_dump()}", flush=True)
    print(f"  url={body.url}", flush=True)


@router.get("/check-auth")
async def check_auth(request: Request, _=Depends(require_token)):
    return {"ok": True}


@router.post("/upload", status_code=202)
async def upload(
    body: UploadRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    session: Session = Depends(get_session),
    _=Depends(require_token),
):
    try:
        source = _classify_url(body.url)
    except HTTPException as exc:
        if exc.status_code == 400:
            _print_bad_request_details(request, body)
        raise

    if source["platform"] == "youtube":
        existing = repo.get_completed_video_by_source(session, "youtube", source["source_key"])
        if existing:
            return {"id": existing.id, "status": "queued"}

    video = repo.add_video(
        session,
        source["normalized_url"] if source["platform"] == "youtube" else body.url,
        platform=source["platform"],
        source_key=source["source_key"],
        preview_url=_youtube_preview_url(source["source_key"]) if source["platform"] == "youtube" else None,
    )
    background_tasks.add_task(download_video, video.id)
    return {"id": video.id, "status": "queued"}


@router.get("/api/classifications")
async def api_classifications():
    return {"classifications": CLASSIFICATIONS}


@router.get("/api/videos")
async def api_videos(classification: str | None = None, session: Session = Depends(get_session)):
    if classification and classification not in CLASSIFICATIONS:
        classification = None
    videos = repo.get_all_videos(session, classification)
    return [VideoOut.from_model(v) for v in videos]
```

Continue this exact pattern (add `Depends(get_session)`/`Depends(require_token)` params, swap `db.`/`services.` calls, swap `serialize_video` for `VideoOut.from_model`) for `upload_file`, `api_classify_video`, `api_choose_video_version`, `api_choose_audio`, `api_delete_video`, `api_video`, `api_prepare_video` — port each function body from `router.py` one at a time, run its specific test after each, don't batch all of them before testing.

- [ ] **Step 4:** Run `tests/test_api_videos.py` after every 1-2 ported endpoints, not just at the end.
- [ ] **Step 5:** Commit once the whole file's tests pass: `"feat: add api.v1.videos router"`

### Task 5.3: `api/v1/streaming.py`

Port `_guess_mime`, `_range_not_satisfiable`, `_parse_byte_range`, `_iter_file_range`, `_resolve_hls_source`, `video_preview`, `stream_video`, `hls_asset`, plus the constants `PREVIEWS_DIR`, `VIDEO_CHUNK_SIZE`, `VIDEO_CACHE_CONTROL`, `_positive_int_env`, `_video_stream_slots` (from `router.py`). Same TDD pattern as 5.2 — port `tests/test_api.py`'s stream/hls/preview tests into `tests/test_api_streaming.py`, one endpoint at a time.

- [ ] Commit: `"feat: add api.v1.streaming router"`

### Task 5.4: `api/v1/library.py`

Port `api_library_scan`. Small file.

- [ ] Commit: `"feat: add api.v1.library router"`

### Task 5.5: `api/v1/pages.py`

Port `classify_video_endpoint`, `choose_video_version_endpoint`, `videos_page` (SSR form + page routes, un-gated, per design doc). **No `move_video_endpoint`** — reorder was removed.

- [ ] Commit: `"feat: add api.v1.pages router"`

### Task 5.6: `api/v1/assets.py`

Port `ROOT_STATIC_ASSETS`, `_static_asset_cache`, `_load_static_asset_cache`, `_static_asset_response`, `favicon`, `apple_touch_icon`, `apple_splash`, `apple_splash_optimized`, `splash_asset`, `vendor_asset` (`/assets/vendor/{filename}`), `app_asset` (`/assets/app/{filename}`), `manifest`, `SPLASH_MIME_TYPES`, `SPLASH_ICON`.

- [ ] Commit: `"feat: add api.v1.assets router"`

### Task 5.7: Rewire `main.py`, retire `router.py`/`services.py`/`db.py`/`views/serializers.py`

**Files:** Modify `main.py`, `tests/test_api.py` (or its split successors), delete `router.py`, `services.py`, `db.py`, `views/serializers.py`.

- [ ] **Step 1:** Rewrite `main.py`:

```python
from contextlib import asynccontextmanager
import multiprocessing

from alembic import command
from alembic.config import Config
from dotenv import load_dotenv
from fastapi import FastAPI
from setproctitle import setproctitle

from api.v1 import assets, library, pages, streaming, videos
from config import SPLASH_DIR, VIDEOS_DIR
from middleware import setup_middleware
from repositories.backfills import run_backfills  # see Step 2
from api.v1.assets import _load_static_asset_cache

load_dotenv()

PROCESS_NAME = "[PatataTube]"


def _set_process_name(name: str = PROCESS_NAME) -> None:
    multiprocessing.current_process().name = name
    setproctitle(name)


def _run_migrations() -> None:
    cfg = Config("alembic.ini")
    command.upgrade(cfg, "head")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _set_process_name()
    VIDEOS_DIR.mkdir(exist_ok=True)
    SPLASH_DIR.mkdir(parents=True, exist_ok=True)
    _run_migrations()
    run_backfills()
    _load_static_asset_cache()
    yield


app = FastAPI(lifespan=lifespan)
setup_middleware(app)
app.include_router(videos.router)
app.include_router(streaming.router)
app.include_router(library.router)
app.include_router(pages.router)
app.include_router(assets.router)
```

- [ ] **Step 2:** Create `repositories/backfills.py` with the five backfill functions ported from `db.py:131-241` (`_backfill_positions`, `_backfill_library_added_at`, `_delete_error_videos`, `_backfill_video_versions`) and `_backfill_youtube_preview_urls` (`db.py:576`), each rewritten against a `Session`/`select` instead of raw SQL, plus a `run_backfills()` entry point that opens one session and runs all five in the same order as today's `init_db` (`db.py:124-128`: youtube preview URLs → positions → library added_at → video versions → delete error videos). Write a test `tests/test_repositories_backfills.py` porting the relevant cases from `tests/test_db.py` (backfill tests) first, TDD as usual.

- [ ] **Step 3:** Delete the old files:

```bash
git rm router.py services.py db.py
# only if not already removed in Chunk 3 Task 3.3:
git rm -f views/serializers.py 2>/dev/null || true
```

- [ ] **Step 4:** Rewrite `tests/test_api.py`'s `client` fixture — replace the `reload(db); reload(main)` pattern with a fixture that sets `DB_PATH` to a temp file, runs migrations via `_run_migrations()` (imported from `main`) instead of `db.init_db()`, and reloads `main`:

```python
@pytest.fixture()
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.sqlite"))
    monkeypatch.setenv("UPLOAD_TOKEN", "test-secret")
    import database
    importlib.reload(database)  # picks up new DB_PATH for get_engine()'s cache
    import main
    importlib.reload(main)
    with TestClient(main.app) as c:
        yield c
```

Split the now-passing `tests/test_api.py` file into `tests/test_api_videos.py`, `tests/test_api_streaming.py`, `tests/test_api_library.py`, `tests/test_api_pages.py`, `tests/test_api_assets.py` per Tasks 5.2-5.6 (each of those tasks' "port failing tests" step already targeted these filenames) — each gets its own copy of the `client` fixture above (or factor it into a `tests/conftest.py` shared fixture, cleaner — do that instead of duplicating across 5 files).

- [ ] **Step 5:** Create `tests/conftest.py` with the shared `client` fixture (moved out of the per-file duplicates), then `git rm tests/test_api.py` once every case has a home in the split files.

- [ ] **Step 6:** Run the full suite:

```bash
python_env/bin/python -m pytest tests/ -v
```

Expected: every test passes, no `db`/`router`/`services` (old) imports remain anywhere.

- [ ] **Step 7:** `grep -rn "^import db$\|^import router$\|^import services$\|from db import\|from router import\|from services import\|views.serializers" --include=*.py .` — expect zero matches outside this plan file itself and the design doc.

- [ ] **Step 8:** Commit: `"refactor: wire main.py to new api/services/repositories layers; retire db.py, router.py, services.py"`

---

## Chunk 6: Final verification and stamp check

**Files:** none (verification only)

- [ ] **Step 1:** Full test suite:

```bash
python_env/bin/python -m pytest tests/ -v
```

Expected: all green (same total count as pre-refactor — ~235 collected today, though a couple may error at collection if Redis/OpenAI-dependent test deps are missing locally; establish the real baseline count on `main` before starting and compare — plus whatever net-new test functions this plan added minus retired duplicates. A lower count is a red flag, investigate before proceeding).

- [ ] **Step 2:** Manual smoke test against a **copy** of the real DB (never the original):

```bash
cp data/watch_later.sqlite /tmp/smoke.sqlite
DB_PATH=/tmp/smoke.sqlite UPLOAD_TOKEN=smoke-token python_env/bin/uvicorn main:app --port 3099 &
sleep 1
curl -s localhost:3099/ | head -c 200
curl -s localhost:3099/api/videos | python_env/bin/python -m json.tool | head -40
curl -s -H "Range: bytes=0-1023" -o /dev/null -w "%{http_code}\n" "localhost:3099/videos/1/stream?token=smoke-token"
kill %1
```

Expected: `/` returns HTML, `/api/videos` returns the video list JSON, the range request returns `206`.

- [ ] **Step 3:** Byte-identical JSON diff — capture `/api/videos` from the pre-refactor branch and this branch against the same DB copy, diff them:

```bash
# on main (pre-refactor):
git stash
DB_PATH=/tmp/smoke.sqlite python_env/bin/uvicorn main:app --port 3098 &
sleep 1; curl -s localhost:3098/api/videos | python_env/bin/python -m json.tool > /tmp/before.json; kill %1
git stash pop
# on this branch:
DB_PATH=/tmp/smoke.sqlite python_env/bin/uvicorn main:app --port 3099 &
sleep 1; curl -s localhost:3099/api/videos | python_env/bin/python -m json.tool > /tmp/after.json; kill %1
diff /tmp/before.json /tmp/after.json
```

Expected: no diff. (Adjust the "pre-refactor" checkout to whatever commit predates Chunk 1 if not literally `main`.)

- [ ] **Step 4:** Confirm `alembic_version` table exists on the real DB with value `0001` (from Chunk 1 Task 1.5 Step 6) and that no `alembic upgrade` has been run against it inadvertently:

```bash
sqlite3 data/watch_later.sqlite "select * from alembic_version;"
```

Expected: one row, `0001`.

- [ ] **Step 5:** Update `CLAUDE.md`'s "Layering" section to describe the new structure (models/repositories/schemas/services/api) in place of the current `db.py`/`services.py`/`views/` description, and the "Commands" section if `alembic upgrade head` needs to be documented as a one-time setup step for fresh clones.

- [ ] **Step 6:** Final commit: `"docs: update CLAUDE.md for layered architecture"`

- [ ] **Step 7:** Push the branch and open a PR (only if the user asks — do not push/open a PR unprompted per this repo's working agreement).

---

## Notes for the implementer

- This plan was written for **subagent-driven-development** or **executing-plans** execution. Each chunk has commit checkpoints — do not let uncommitted work span a chunk boundary.
- The riskiest single piece of logic in this entire refactor is Chunk 2 Task 2.4 (version-sync). If anything is going to have a subtle behavioral regression, it's there. Budget extra review time on that task specifically.
- Chunk 5 is large by line count but mechanical — resist the urge to "improve" anything while porting; this is a pure move, verified by the Chunk 6 byte-identical JSON diff.
- No `plan-document-reviewer` subagent is available in this environment, so this plan did not go through the automated plan-review loop described in the writing-plans skill. Read it yourself before execution, especially Chunk 1 Task 1.5 (Alembic stamp) and Chunk 2 Task 2.4 (version-sync) — those are where a misread of the design doc would be most damaging.
