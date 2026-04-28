import sqlite3
import os
from datetime import datetime, timezone
from pathlib import Path

def _conn():
    conn = sqlite3.connect(os.getenv("DB_PATH", "data/watch_later.db"), timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    Path(os.getenv("DB_PATH", "data/watch_later.db")).parent.mkdir(parents=True, exist_ok=True)
    with _conn() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS videos (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                url       TEXT NOT NULL,
                filename  TEXT,
                status    TEXT NOT NULL DEFAULT 'queued',
                error_msg TEXT,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS progress (
                video_id         INTEGER PRIMARY KEY REFERENCES videos(id),
                position_seconds REAL NOT NULL DEFAULT 0
            );
        """)


def add_video(url: str) -> int:
    with _conn() as conn:
        cur = conn.execute(
            "INSERT INTO videos (url, created_at) VALUES (?, ?)",
            (url, datetime.now(timezone.utc).isoformat()),
        )
        return cur.lastrowid


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None


def get_all_videos() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute("SELECT * FROM videos ORDER BY created_at DESC").fetchall()
        return [dict(r) for r in rows]


def update_video(video_id: int, status: str, filename: str | None = None, error_msg: str | None = None):
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET status=?, filename=?, error_msg=? WHERE id=?",
            (status, filename, error_msg, video_id),
        )


def get_progress(video_id: int) -> float:
    with _conn() as conn:
        row = conn.execute(
            "SELECT position_seconds FROM progress WHERE video_id = ?", (video_id,)
        ).fetchone()
        return row[0] if row else 0.0


def upsert_progress(video_id: int, position_seconds: float):
    with _conn() as conn:
        conn.execute(
            """INSERT INTO progress (video_id, position_seconds) VALUES (?, ?)
               ON CONFLICT(video_id) DO UPDATE SET position_seconds=excluded.position_seconds""",
            (video_id, position_seconds),
        )
