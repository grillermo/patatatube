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


def _add_column(conn: sqlite3.Connection, ddl: str) -> None:
    # Multiple uvicorn worker processes run init_db() concurrently at boot
    # against the same DB file, so a "check columns, then ALTER" guard can
    # still race between two workers. Catch the duplicate-column error
    # instead of relying on the pre-check alone.
    try:
        conn.execute(ddl)
    except sqlite3.OperationalError as e:
        if "duplicate column name" not in str(e):
            raise


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
            _add_column(conn, "ALTER TABLE videos ADD COLUMN platform TEXT")
        if "source_key" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN source_key TEXT")
        if "title" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN title TEXT")
        if "preview_url" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN preview_url TEXT")
        if "position" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN position INTEGER")
        if "classification" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN classification TEXT NOT NULL DEFAULT 'children'")
        if "source" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN source TEXT NOT NULL DEFAULT 'download'")
        if "source_path" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN source_path TEXT")
        if "converted_path" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN converted_path TEXT")
        if "show_title" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN show_title TEXT")
        if "season" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN season INTEGER")
        if "episode" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN episode INTEGER")
        if "summary" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN summary TEXT")
        if "plex_rating_key" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN plex_rating_key TEXT")
        if "show_rating_key" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN show_rating_key TEXT")
        if "deleted_at" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN deleted_at TEXT")
        if "chosen_version_id" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN chosen_version_id INTEGER")
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS video_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                video_id INTEGER NOT NULL,
                source_path TEXT NOT NULL,
                label TEXT,
                status TEXT NOT NULL DEFAULT 'unconverted',
                converted_path TEXT,
                error_msg TEXT,
                position INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(video_id, source_path)
            );
            CREATE INDEX IF NOT EXISTS idx_video_versions_video_id ON video_versions(video_id);
            """
        )
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_videos_source_path ON videos(source_path)"
        )
        _backfill_youtube_preview_urls(conn)
        _backfill_positions(conn)
        _backfill_library_added_at(conn)
        _backfill_video_versions(conn)
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


# Positions assigned by scan order are small sequential ints; positions derived
# from an "added" timestamp are unix seconds (~1.7e9). This threshold tells the
# two apart so the backfill only rewrites rows still on scan-order positions,
# making it idempotent across restarts.
_ADDED_AT_POSITION_FLOOR = 1_000_000_000


def _backfill_library_added_at(conn: sqlite3.Connection) -> int:
    """Reset legacy library rows to sort by real file 'added' time.

    Old rows carry created_at = scan time and position = scan order, so they
    surface in the wrong order. Rewrite both from the source file's mtime (the
    best 'added' signal available without hitting Plex here). A later Plex
    rescan refines these from addedAt. Idempotent via _ADDED_AT_POSITION_FLOOR.
    """
    rows = conn.execute(
        "SELECT id, source_path FROM videos "
        "WHERE source = 'library' AND source_path IS NOT NULL "
        "AND (position IS NULL OR position < ?)",
        (_ADDED_AT_POSITION_FLOOR,),
    ).fetchall()
    changed = 0
    for row in rows:
        try:
            mtime = int(Path(row["source_path"]).stat().st_mtime)
        except OSError:
            continue
        conn.execute(
            "UPDATE videos SET position = ?, created_at = ? WHERE id = ?",
            (mtime, datetime.fromtimestamp(mtime, timezone.utc).isoformat(), row["id"]),
        )
        changed += 1
    return changed


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


def _backfill_video_versions(conn: sqlite3.Connection) -> int:
    rows = conn.execute(
        """
        SELECT *
        FROM videos
        WHERE source = 'library'
          AND source_path IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM video_versions WHERE video_versions.video_id = videos.id
          )
        """
    ).fetchall()
    changed = 0
    for row in rows:
        cur = conn.execute(
            """
            INSERT INTO video_versions (
                video_id, source_path, label, status, converted_path, error_msg, position
            )
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """,
            (
                row["id"],
                row["source_path"],
                "Version 1",
                row["status"] or "unconverted",
                row["converted_path"],
                row["error_msg"],
            ),
        )
        conn.execute(
            "UPDATE videos SET chosen_version_id = COALESCE(chosen_version_id, ?) WHERE id = ?",
            (cur.lastrowid, row["id"]),
        )
        changed += 1

    for row in conn.execute(
        """
        SELECT id
        FROM videos
        WHERE source = 'library'
          AND chosen_version_id IS NULL
          AND EXISTS (SELECT 1 FROM video_versions WHERE video_versions.video_id = videos.id)
        """
    ).fetchall():
        _ensure_chosen_version(conn, row["id"])
        changed += 1

    return changed


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


def _video_with_versions(conn: sqlite3.Connection, row: sqlite3.Row | None) -> dict | None:
    if row is None:
        return None
    video = dict(row)
    if video.get("source") == "library":
        video["versions"] = _get_video_versions(conn, video["id"])
    return video


def _get_video_versions(conn: sqlite3.Connection, video_id: int) -> list[dict]:
    chosen = conn.execute(
        "SELECT chosen_version_id FROM videos WHERE id = ?",
        (video_id,),
    ).fetchone()
    chosen_id = chosen["chosen_version_id"] if chosen else None
    rows = conn.execute(
        """
        SELECT *
        FROM video_versions
        WHERE video_id = ?
        ORDER BY position ASC, id ASC
        """,
        (video_id,),
    ).fetchall()
    versions = [dict(row) for row in rows]
    for version in versions:
        version["is_chosen"] = version["id"] == chosen_id
    return versions


def get_video_versions(video_id: int) -> list[dict]:
    with _conn() as conn:
        return _get_video_versions(conn, video_id)


def get_version_labels(source_paths: list[str]) -> dict[str, str]:
    """Map source_path -> stored label for the given paths (only non-empty labels).

    Used by the scan path as an idempotency guard: if every version of a movie
    already has a stored label, we reuse them and skip the LLM relabel call.
    """
    if not source_paths:
        return {}
    placeholders = ",".join("?" for _ in source_paths)
    with _conn() as conn:
        rows = conn.execute(
            f"""
            SELECT source_path, label
            FROM video_versions
            WHERE source_path IN ({placeholders})
            """,
            source_paths,
        ).fetchall()
    return {row["source_path"]: row["label"] for row in rows if (row["label"] or "").strip()}


def get_video_version(video_id: int, version_id: int | None = None) -> dict | None:
    with _conn() as conn:
        if version_id is None:
            version_id = _ensure_chosen_version(conn, video_id)
            if version_id is None:
                return None
        row = conn.execute(
            """
            SELECT *
            FROM video_versions
            WHERE video_id = ? AND id = ?
            """,
            (video_id, version_id),
        ).fetchone()
        if not row:
            return None
        version = dict(row)
        video = conn.execute("SELECT chosen_version_id FROM videos WHERE id = ?", (video_id,)).fetchone()
        version["is_chosen"] = bool(video and video["chosen_version_id"] == version["id"])
        return version


def _sync_video_from_chosen(conn: sqlite3.Connection, video_id: int) -> None:
    row = conn.execute(
        """
        SELECT source_path, converted_path, status, error_msg
        FROM video_versions
        WHERE id = (SELECT chosen_version_id FROM videos WHERE id = ?)
          AND video_id = ?
        """,
        (video_id, video_id),
    ).fetchone()
    if not row:
        return
    conn.execute(
        """
        UPDATE videos
        SET source_path = ?,
            converted_path = ?,
            status = ?,
            error_msg = ?
        WHERE id = ?
        """,
        (row["source_path"], row["converted_path"], row["status"], row["error_msg"], video_id),
    )


def _ensure_chosen_version(conn: sqlite3.Connection, video_id: int) -> int | None:
    current = conn.execute(
        """
        SELECT chosen_version_id
        FROM videos
        WHERE id = ?
        """,
        (video_id,),
    ).fetchone()
    if current and current["chosen_version_id"]:
        exists = conn.execute(
            """
            SELECT 1
            FROM video_versions
            WHERE video_id = ? AND id = ?
            """,
            (video_id, current["chosen_version_id"]),
        ).fetchone()
        if exists:
            _sync_video_from_chosen(conn, video_id)
            return current["chosen_version_id"]

    row = conn.execute(
        """
        SELECT id
        FROM video_versions
        WHERE video_id = ?
        ORDER BY position ASC, id ASC
        LIMIT 1
        """,
        (video_id,),
    ).fetchone()
    if not row:
        return None
    conn.execute("UPDATE videos SET chosen_version_id = ? WHERE id = ?", (row["id"], video_id))
    _sync_video_from_chosen(conn, video_id)
    return row["id"]


def set_chosen_version(video_id: int, version_id: int) -> bool:
    with _conn() as conn:
        row = conn.execute(
            """
            SELECT id
            FROM video_versions
            WHERE video_id = ? AND id = ?
            """,
            (video_id, version_id),
        ).fetchone()
        if not row:
            return False
        conn.execute("UPDATE videos SET chosen_version_id = ? WHERE id = ?", (version_id, video_id))
        _sync_video_from_chosen(conn, video_id)
        return True


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return _video_with_versions(conn, row)


def delete_video(video_id: int):
    with _conn() as conn:
        conn.execute("DELETE FROM video_versions WHERE video_id = ?", (video_id,))
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
    return [_video_with_versions(conn, r) for r in rows]


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


def _incoming_versions(item: dict) -> list[dict]:
    versions = item.get("versions") or [
        {"source_path": item["source_path"], "label": "Version 1"}
    ]
    return [
        {
            "source_path": version["source_path"],
            "label": version.get("label") or f"Version {index + 1}",
            "position": index,
        }
        for index, version in enumerate(versions)
        if version.get("source_path")
    ]


def _sync_versions(conn: sqlite3.Connection, video_id: int, item: dict) -> None:
    incoming = _incoming_versions(item)
    if not incoming:
        conn.execute("DELETE FROM video_versions WHERE video_id = ?", (video_id,))
        _ensure_chosen_version(conn, video_id)
        return

    keep = []
    for version in incoming:
        row = conn.execute(
            """
            SELECT id
            FROM video_versions
            WHERE video_id = ? AND source_path = ?
            """,
            (video_id, version["source_path"]),
        ).fetchone()
        if row:
            keep.append(row["id"])
            conn.execute(
                """
                UPDATE video_versions
                SET label = ?, position = ?
                WHERE id = ?
                """,
                (version["label"], version["position"], row["id"]),
            )
        else:
            cur = conn.execute(
                """
                INSERT INTO video_versions (video_id, source_path, label, position)
                VALUES (?, ?, ?, ?)
                """,
                (video_id, version["source_path"], version["label"], version["position"]),
            )
            keep.append(cur.lastrowid)

    placeholders = ",".join("?" for _ in keep)
    conn.execute(
        f"DELETE FROM video_versions WHERE video_id = ? AND id NOT IN ({placeholders})",
        (video_id, *keep),
    )
    _ensure_chosen_version(conn, video_id)


def upsert_library_video(item: dict) -> tuple[int, str]:
    """Insert or update a library row keyed on Plex rating key when available."""
    with _conn() as conn:
        if item.get("plex_rating_key"):
            row = conn.execute(
                "SELECT id, deleted_at FROM videos WHERE plex_rating_key = ?",
                (item["plex_rating_key"],),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id, deleted_at FROM videos WHERE source_path = ?",
                (item["source_path"],),
            ).fetchone()

        # The real "added to library" instant: Plex addedAt (unix seconds), with a
        # filesystem-mtime fallback supplied by the scanner. Both created_at and
        # position are derived from it so the standard "position DESC, created_at DESC"
        # ordering surfaces the newest-added library items first.
        added_at = item.get("added_at")
        if added_at:
            created_at = datetime.fromtimestamp(int(added_at), timezone.utc).isoformat()
            position = int(added_at)
        else:
            created_at = datetime.now(timezone.utc).isoformat()
            position = None

        if row:
            if row["deleted_at"]:
                return row["id"], "tombstoned"
            conn.execute(
                """
                UPDATE videos
                SET url = ?, title = ?, classification = ?, show_title = ?, season = ?,
                    episode = ?, summary = ?, plex_rating_key = ?, show_rating_key = ?,
                    created_at = COALESCE(?, created_at),
                    position = COALESCE(?, position)
                WHERE id = ?
                """,
                (
                    item["source_path"],
                    item.get("title"),
                    item["classification"],
                    item.get("show_title"),
                    item.get("season"),
                    item.get("episode"),
                    item.get("summary"),
                    item.get("plex_rating_key"),
                    item.get("show_rating_key"),
                    created_at if added_at else None,
                    position,
                    row["id"],
                ),
            )
            _sync_versions(conn, row["id"], item)
            return row["id"], "updated"

        if position is None:
            position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
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
                created_at,
                position,
            ),
        )
        _sync_versions(conn, cur.lastrowid, item)
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
            """
            SELECT converted_path FROM video_versions WHERE converted_path IS NOT NULL
            UNION
            SELECT converted_path
            FROM videos
            WHERE converted_path IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM video_versions WHERE video_versions.video_id = videos.id
              )
            """
        ).fetchall()
        return {r["converted_path"] for r in rows}


def set_library_state(
    video_id: int,
    status: str,
    converted_path: str | None = None,
    error_msg: str | None = None,
    version_id: int | None = None,
) -> None:
    """Status updates for library rows. Unlike update_video, never deletes the row."""
    with _conn() as conn:
        video = conn.execute("SELECT source FROM videos WHERE id = ?", (video_id,)).fetchone()
        if video and video["source"] == "library":
            if version_id is None:
                version_id = _ensure_chosen_version(conn, video_id)
            if version_id is not None:
                conn.execute(
                    """
                    UPDATE video_versions
                    SET status = ?,
                        converted_path = COALESCE(?, converted_path),
                        error_msg = ?
                    WHERE video_id = ? AND id = ?
                    """,
                    (status, converted_path, error_msg, video_id, version_id),
                )
                if error_msg and status == "unconverted":
                    conn.execute(
                        """
                        UPDATE video_versions
                        SET converted_path = NULL
                        WHERE video_id = ? AND id = ?
                        """,
                        (video_id, version_id),
                    )
                _sync_video_from_chosen(conn, video_id)
                return

        conn.execute(
            """
            UPDATE videos
            SET status = ?, converted_path = COALESCE(?, converted_path), error_msg = ?
            WHERE id = ?
            """,
            (status, converted_path, error_msg, video_id),
        )
