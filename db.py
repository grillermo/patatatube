import sqlite3
import os
from datetime import datetime, timezone
from pathlib import Path

CLASSIFICATIONS = ["children", "adults", "education", "tv", "movies"]


def _conn():
    conn = sqlite3.connect(os.getenv("DB_PATH", "data/watch_later.sqlite"), timeout=30)
    conn.row_factory = sqlite3.Row
    # WAL lets multiple worker processes read while one writes, instead of
    # locking the whole DB. busy_timeout waits out brief write contention.
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
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
        if "position" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN position INTEGER")
        if "classification" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN classification TEXT NOT NULL DEFAULT 'children'")
        if "source" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN source TEXT NOT NULL DEFAULT 'download'")
        if "source_path" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN source_path TEXT")
        if "converted_path" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN converted_path TEXT")
        if "show_title" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN show_title TEXT")
        if "season" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN season INTEGER")
        if "episode" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN episode INTEGER")
        if "summary" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN summary TEXT")
        if "plex_rating_key" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN plex_rating_key TEXT")
        if "show_rating_key" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN show_rating_key TEXT")
        if "deleted_at" not in columns:
            conn.execute("ALTER TABLE videos ADD COLUMN deleted_at TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_videos_source_path ON videos(source_path)"
        )
        _backfill_youtube_preview_urls(conn)
        _backfill_positions(conn)
        _delete_error_videos(conn)


def _backfill_positions(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        "SELECT id FROM videos WHERE position IS NULL ORDER BY created_at ASC"
    ).fetchall()
    if not rows:
        return 0
    current_max = conn.execute("SELECT MAX(position) FROM videos").fetchone()[0]
    start = current_max if current_max is not None else 0
    for offset, row in enumerate(rows):
        conn.execute("UPDATE videos SET position = ? WHERE id = ?", (start + offset + 1, row["id"]))
    return len(rows)


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
        next_position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
        cur = conn.execute(
            """
            INSERT INTO videos (url, platform, source_key, title, preview_url, created_at, position)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                url,
                platform,
                source_key,
                title,
                preview_url,
                datetime.now(timezone.utc).isoformat(),
                next_position,
            ),
        )
        return cur.lastrowid


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None


def delete_video(video_id: int):
    with _conn() as conn:
        conn.execute("DELETE FROM videos WHERE id = ?", (video_id,))


def get_all_videos(classification: str | None = None) -> list[dict]:
    with _conn() as conn:
        if classification:
            rows = conn.execute(
                "SELECT * FROM videos WHERE deleted_at IS NULL AND classification = ?"
                " ORDER BY position DESC, created_at DESC",
                (classification,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM videos WHERE deleted_at IS NULL ORDER BY position DESC, created_at DESC"
            ).fetchall()
        return [dict(r) for r in rows]


def set_video_classification(video_id: int, classification: str) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET classification = ? WHERE id = ?", (classification, video_id))


def move_video(video_id: int, direction: str) -> bool:
    if direction not in ("up", "down"):
        return False
    with _conn() as conn:
        current = conn.execute(
            "SELECT position FROM videos WHERE id = ?", (video_id,)
        ).fetchone()
        if not current or current["position"] is None:
            return False
        pos = current["position"]
        if direction == "up":
            neighbor = conn.execute(
                "SELECT id, position FROM videos WHERE position > ? ORDER BY position ASC LIMIT 1",
                (pos,),
            ).fetchone()
        else:
            neighbor = conn.execute(
                "SELECT id, position FROM videos WHERE position < ? ORDER BY position DESC LIMIT 1",
                (pos,),
            ).fetchone()
        if not neighbor:
            return False
        conn.execute(
            "UPDATE videos SET position = ? WHERE id = ?", (neighbor["position"], video_id)
        )
        conn.execute(
            "UPDATE videos SET position = ? WHERE id = ?", (pos, neighbor["id"])
        )
        return True


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


def upsert_library_video(item: dict) -> tuple[int, str]:
    """Insert or update a library row keyed on source_path.

    Returns (video_id, status) with status in {"created", "updated", "tombstoned"}.
    Tombstoned rows are left untouched so a rescan never resurrects a delete.
    """
    with _conn() as conn:
        row = conn.execute(
            "SELECT id, deleted_at FROM videos WHERE source_path = ?",
            (item["source_path"],),
        ).fetchone()
        if row:
            if row["deleted_at"]:
                return row["id"], "tombstoned"
            conn.execute(
                """
                UPDATE videos
                SET title = ?, classification = ?, show_title = ?, season = ?,
                    episode = ?, summary = ?, plex_rating_key = ?, show_rating_key = ?
                WHERE id = ?
                """,
                (
                    item.get("title"),
                    item["classification"],
                    item.get("show_title"),
                    item.get("season"),
                    item.get("episode"),
                    item.get("summary"),
                    item.get("plex_rating_key"),
                    item.get("show_rating_key"),
                    row["id"],
                ),
            )
            return row["id"], "updated"

        next_position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
        cur = conn.execute(
            """
            INSERT INTO videos (
                url, title, status, classification, source, source_path,
                show_title, season, episode, summary, plex_rating_key,
                show_rating_key, created_at, position
            )
            VALUES (?, ?, 'unconverted', ?, 'library', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item["source_path"],
                item.get("title"),
                item["classification"],
                item["source_path"],
                item.get("show_title"),
                item.get("season"),
                item.get("episode"),
                item.get("summary"),
                item.get("plex_rating_key"),
                item.get("show_rating_key"),
                datetime.now(timezone.utc).isoformat(),
                next_position,
            ),
        )
        return cur.lastrowid, "created"


def tombstone_video(video_id: int) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET deleted_at = ? WHERE id = ?",
            (datetime.now(timezone.utc).isoformat(), video_id),
        )


def get_converted_paths() -> set[str]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT converted_path FROM videos WHERE converted_path IS NOT NULL"
        ).fetchall()
        return {r["converted_path"] for r in rows}


def set_library_state(
    video_id: int,
    status: str,
    converted_path: str | None = None,
    error_msg: str | None = None,
) -> None:
    """Status updates for library rows. Unlike update_video, never deletes the row."""
    with _conn() as conn:
        conn.execute(
            """
            UPDATE videos
            SET status = ?, converted_path = COALESCE(?, converted_path), error_msg = ?
            WHERE id = ?
            """,
            (status, converted_path, error_msg, video_id),
        )

