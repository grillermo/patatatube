import sqlite3
import os
from datetime import datetime, timezone
from pathlib import Path


def _conn():
    conn = sqlite3.connect(os.getenv("DB_PATH", "data/watch_later.sqlite"), timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    Path(os.getenv("DB_PATH", "data/watch_later.db")).parent.mkdir(parents=True, exist_ok=True)
    with _conn() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS videos (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                url       TEXT NOT NULL,
                platform  TEXT,
                source_key TEXT,
                title     TEXT,
                filename  TEXT,
                status    TEXT NOT NULL DEFAULT 'queued',
                error_msg TEXT,
                created_at TEXT NOT NULL
            );
        """)
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
        if "platform" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN platform TEXT")
        if "source_key" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN source_key TEXT")
        if "title" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN title TEXT")
        if "preview_url" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN preview_url TEXT")
        _backfill_youtube_preview_urls(conn)
        _delete_error_videos(conn)


def _delete_error_videos(conn: sqlite3.Connection) -> int:
    error_ids = [
        row["id"]
        for row in conn.execute("SELECT id FROM videos WHERE status = 'error'").fetchall()
    ]
    if not error_ids:
        return 0

    placeholders = ",".join("?" for _ in error_ids)
    conn.execute(f"DELETE FROM videos WHERE id IN ({placeholders})", error_ids)
    return len(error_ids)


def add_video(
    url: str,
    platform: str | None = None,
    source_key: str | None = None,
    title: str | None = None,
    preview_url: str | None = None,
) -> int:
    with _conn() as conn:
        cur = conn.execute(
            """
            INSERT INTO videos (url, platform, source_key, title, preview_url, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (url, platform, source_key, title, preview_url, datetime.now(timezone.utc).isoformat()),
        )
        return cur.lastrowid


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None


def delete_video(video_id: int):
    with _conn() as conn:
        conn.execute("DELETE FROM videos WHERE id = ?", (video_id,))


def get_all_videos() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute("SELECT * FROM videos ORDER BY created_at DESC").fetchall()
        return [dict(r) for r in rows]


def get_completed_video_by_source(platform: str, source_key: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute(
            """
            SELECT * FROM videos
            WHERE platform = ? AND source_key = ? AND status = 'done'
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (platform, source_key),
        ).fetchone()
        return dict(row) if row else None


def update_video(
    video_id: int,
    status: str,
    filename: str | None = None,
    error_msg: str | None = None,
    title: str | None = None,
    preview_url: str | None = None,
):
    if status == "error":
        delete_video(video_id)
        return

    with _conn() as conn:
        conn.execute(
            """
            UPDATE videos
            SET status = ?,
                filename = COALESCE(?, filename),
                error_msg = ?,
                title = COALESCE(?, title),
                preview_url = COALESCE(?, preview_url)
            WHERE id = ?
            """,
            (status, filename, error_msg, title, preview_url, video_id),
        )


def youtube_preview_url(source_key: str | None) -> str | None:
    if not source_key:
        return None
    return f"https://i.ytimg.com/vi/{source_key}/hqdefault.jpg"


def _backfill_youtube_preview_urls(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        """
        SELECT id, source_key
        FROM videos
        WHERE platform = 'youtube'
          AND source_key IS NOT NULL
          AND source_key != ''
          AND (preview_url IS NULL OR preview_url = '')
        """
    ).fetchall()

    updated = 0
    for row in rows:
        preview_url = youtube_preview_url(row["source_key"])
        if not preview_url:
            continue
        conn.execute("UPDATE videos SET preview_url = ? WHERE id = ?", (preview_url, row["id"]))
        updated += 1
    return updated

