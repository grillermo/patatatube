# tests/test_db.py
import importlib
import pytest

@pytest.fixture(autouse=True)
def tmp_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    db.init_db()
    yield db


@pytest.fixture()
def fresh_db(monkeypatch, tmp_path):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import db
    importlib.reload(db)
    db.init_db()
    yield

def test_add_and_get_video(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/123")
    assert vid_id == 1
    video = tmp_db.get_video(1)
    assert video["url"] == "https://twitter.com/x/status/123"
    assert video["status"] == "queued"
    assert video["filename"] is None

def test_update_video_status(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/456")
    tmp_db.update_video(vid_id, status="done", filename="456.mp4")
    video = tmp_db.get_video(vid_id)
    assert video["status"] == "done"
    assert video["filename"] == "456.mp4"

def test_update_video_error(tmp_db):
    vid_id = tmp_db.add_video("https://twitter.com/x/status/789")
    tmp_db.update_video(vid_id, status="error", error_msg="Download failed")
    assert tmp_db.get_video(vid_id) is None


def test_set_resume_secs_round_trips(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/1", "twitter")
    tmp_db.set_resume_secs(video_id, 123.5)
    assert tmp_db.get_video(video_id)["resume_secs"] == 123.5


def test_resume_secs_defaults_to_zero(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/2", "twitter")
    assert tmp_db.get_video(video_id)["resume_secs"] == 0


def test_set_resume_secs_clamps_negative(tmp_db):
    video_id = tmp_db.add_video("https://x.com/i/status/3", "twitter")
    tmp_db.set_resume_secs(video_id, -5)
    assert tmp_db.get_video(video_id)["resume_secs"] == 0


@pytest.mark.parametrize("secs", [float("nan"), float("inf"), float("-inf")])
def test_set_resume_secs_rejects_non_finite(tmp_db, secs):
    video_id = tmp_db.add_video("https://x.com/i/status/finite", "twitter")
    with pytest.raises(ValueError, match="finite"):
        tmp_db.set_resume_secs(video_id, secs)


def test_init_db_is_idempotent_with_resume_secs(tmp_db):
    tmp_db.init_db()
    tmp_db.init_db()
    video_id = tmp_db.add_video("https://x.com/i/status/4", "twitter")
    assert tmp_db.get_video(video_id)["resume_secs"] == 0


def test_init_db_deletes_legacy_error_videos(tmp_db):
    good_id = tmp_db.add_video("https://twitter.com/x/status/123")
    bad_id = tmp_db.add_video("https://twitter.com/x/status/789")

    with tmp_db._conn() as conn:
        conn.execute(
            "UPDATE videos SET status = ?, error_msg = ? WHERE id = ?",
            ("error", "Download failed", bad_id),
        )

    tmp_db.init_db()

    assert tmp_db.get_video(good_id) is not None
    assert tmp_db.get_video(bad_id) is None

def test_get_all_videos(tmp_db):
    tmp_db.add_video("https://twitter.com/x/status/1")
    tmp_db.add_video("https://twitter.com/x/status/2")
    videos = tmp_db.get_all_videos()
    assert len(videos) == 2


def test_conn_closes_on_exit(tmp_db):
    import sqlite3
    with tmp_db._conn() as conn:
        pass
    # After the context exits the connection must be closed, not left open
    # for the garbage collector to reap (which leaks file descriptors).
    with pytest.raises(sqlite3.ProgrammingError):
        conn.execute("SELECT 1")


def test_video_metadata_fields_and_source_lookup(tmp_db):
    vid_id = tmp_db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
        title="Original Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    tmp_db.update_video(
        vid_id,
        status="done",
        filename="1.mp4",
        title="Saved Title",
        preview_url="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
    )
    video = tmp_db.get_video(vid_id)
    assert video["platform"] == "youtube"
    assert video["source_key"] == "dQw4w9WgXcQ"
    assert video["title"] == "Saved Title"
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"

    existing = tmp_db.get_completed_video_by_source("youtube", "dQw4w9WgXcQ")
    assert existing is not None
    assert existing["id"] == vid_id
    assert existing["filename"] == "1.mp4"

def test_init_db_backfills_youtube_preview_urls(tmp_db):
    vid_id = tmp_db.add_video(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        platform="youtube",
        source_key="dQw4w9WgXcQ",
    )

    with tmp_db._conn() as conn:
        conn.execute("UPDATE videos SET preview_url = NULL WHERE id = ?", (vid_id,))

    tmp_db.init_db()
    video = tmp_db.get_video(vid_id)
    assert video["preview_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"


def test_subtitle_reprobe_backfill_stamps_schema_version(fresh_db):
    import db
    import sqlite3
    import os
    conn = sqlite3.connect(os.getenv("DB_PATH"))
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] >= db.SCHEMA_VERSION
    finally:
        conn.close()


LIBRARY_COLUMNS = {
    "source", "source_path", "converted_path", "show_title", "season", "episode",
    "summary", "plex_rating_key", "show_rating_key", "deleted_at", "chosen_version_id",
    "audio_lang", "subtitle_lang", "preview_version", "show_preview_version", "plex_kind",
}


def _legacy_db(path):
    """A database as the pre-removal code left it: one download, one library row."""
    import sqlite3

    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, platform TEXT,
            source_key TEXT, title TEXT, filename TEXT, status TEXT NOT NULL DEFAULT 'queued',
            error_msg TEXT, created_at TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'download',
            source_path TEXT, converted_path TEXT, plex_kind TEXT, deleted_at TEXT,
            plex_rating_key TEXT, resume_secs REAL NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX idx_videos_source_path ON videos(source_path);
        CREATE TABLE video_versions (id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL,
            source_path TEXT NOT NULL);
        CREATE TABLE jobs (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, video_id INTEGER NOT NULL,
            version_id INTEGER NOT NULL DEFAULT 0, payload TEXT, result TEXT,
            priority INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0, error_msg TEXT, created_at TEXT NOT NULL,
            started_at TEXT, finished_at TEXT);
        INSERT INTO videos (id, url, status, created_at, resume_secs)
            VALUES (1, 'https://youtu.be/x', 'done', '2026-01-01', 42);
        INSERT INTO videos (id, url, status, created_at, source, source_path, plex_kind)
            VALUES (2, '/Volumes/Media/media/movies/a.mkv', 'done', '2026-01-01',
                    'library', '/Volumes/Media/media/movies/a.mkv', 'movies');
        INSERT INTO video_versions (video_id, source_path) VALUES (2, '/Volumes/Media/media/movies/a.mkv');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('convert', 2, '2026-01-01');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('hls', 1, '2026-01-01');
        """
    )
    conn.commit()
    conn.close()


def test_init_db_purges_the_library(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "legacy.sqlite"
    _legacy_db(path)
    monkeypatch.setenv("DB_PATH", str(path))

    db.init_db()
    db.init_db()  # idempotent

    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    rows = conn.execute("SELECT id, resume_secs FROM videos").fetchall()
    jobs = conn.execute("SELECT kind, video_id FROM jobs").fetchall()
    conn.close()

    assert columns.isdisjoint(LIBRARY_COLUMNS)
    assert "video_versions" not in tables
    assert rows == [(1, 42)]
    assert jobs == []


def test_fresh_db_never_creates_library_columns(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "fresh.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    db.init_db()
    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    conn.close()
    assert columns.isdisjoint(LIBRARY_COLUMNS)


def test_init_db_drops_hls(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "hls.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, platform TEXT,
            source_key TEXT, title TEXT, filename TEXT, status TEXT NOT NULL DEFAULT 'queued',
            error_msg TEXT, created_at TEXT NOT NULL, resume_secs REAL NOT NULL DEFAULT 0,
            hls_status TEXT NOT NULL DEFAULT 'none'
        );
        CREATE TABLE jobs (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, video_id INTEGER NOT NULL,
            version_id INTEGER NOT NULL DEFAULT 0, payload TEXT, result TEXT,
            priority INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0, error_msg TEXT, created_at TEXT NOT NULL,
            started_at TEXT, finished_at TEXT);
        INSERT INTO videos (id, url, status, created_at, resume_secs, hls_status)
            VALUES (1, 'https://youtu.be/x', 'done', '2026-01-01', 42, 'done');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('hls', 1, '2026-01-01');
        INSERT INTO jobs (kind, video_id, created_at) VALUES ('sd', 1, '2026-01-01');
        """
    )
    conn.close()
    monkeypatch.setenv("DB_PATH", str(path))

    db.init_db()
    db.init_db()  # idempotent

    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    jobs = conn.execute("SELECT kind FROM jobs").fetchall()
    rows = conn.execute("SELECT id, resume_secs FROM videos").fetchall()
    conn.close()

    assert "hls_status" not in columns
    assert jobs == [("sd",)]
    assert rows == [(1, 42)]


def test_fresh_db_has_no_hls_status(tmp_path, monkeypatch):
    import sqlite3

    import db

    path = tmp_path / "fresh-hls.sqlite"
    monkeypatch.setenv("DB_PATH", str(path))
    db.init_db()
    conn = sqlite3.connect(path)
    columns = {r[1] for r in conn.execute("PRAGMA table_info(videos)")}
    conn.close()
    assert "hls_status" not in columns
