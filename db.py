import sqlite3
import os
import json
import math
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

# Plex media types. Deliberately NOT groups: they have their own tabs, their own
# scan source (plex.py), their own directories, and their own playback rules.
PLEX_KINDS = ("tv", "movies")

# Seeded into `groups` on a fresh database. After that the table is the truth —
# this list is not consulted again and must never be imported as "the groups".
DEFAULT_GROUPS = [
    ("children", "Children", 0),
    ("adults", "Adults", 1),
    ("anabel", "Anabel", 2),
    ("asmr", "ASMR", 3),
]

JOB_KINDS = ("convert", "hls", "normalize")
PRIORITY_INTERACTIVE = 0
PRIORITY_BULK = 100


def _job_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


MAX_JOB_ATTEMPTS = _job_int_env("MAX_JOB_ATTEMPTS", 3)


@contextmanager
def _conn():
    # sqlite3's own connection context manager commits/rolls back but never
    # closes, so `with sqlite3.connect(...) as c` leaks the fd until GC reaps
    # it. Wrap it here to commit on success like `with conn:` and always close
    # on exit, keeping the fd count flat under load.
    conn = sqlite3.connect(os.getenv("DB_PATH", "data/watch_later.sqlite"), timeout=30)
    conn.row_factory = sqlite3.Row
    # WAL lets multiple worker processes read while one writes, instead of
    # locking the whole DB. busy_timeout waits out brief write contention.
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    try:
        with conn:
            yield conn
    finally:
        conn.close()


@contextmanager
def _write_conn():
    """Like _conn(), but takes the write lock before the first read.

    Claiming a job reads the queue and writes the claim in one transaction. A
    deferred transaction starts on a read snapshot and can fail to upgrade with
    SQLITE_BUSY_SNAPSHOT - a busy_timeout does not retry, unlike plain
    SQLITE_BUSY. BEGIN IMMEDIATE takes the write lock up front, so concurrent
    claimers queue on busy_timeout instead of erroring out.
    """
    conn = sqlite3.connect(
        os.getenv("DB_PATH", "data/watch_later.sqlite"), timeout=30, isolation_level=None
    )
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()


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
        if "hls_status" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN hls_status TEXT NOT NULL DEFAULT 'none'")
        if "audio_lang" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN audio_lang TEXT")
        # NULL = never chosen (client falls back to the server's default-flagged
        # subtitle track); "" = explicitly off; anything else = the chosen
        # language tag. See views/serializers.py for how this is exposed.
        if "subtitle_lang" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN subtitle_lang TEXT")
        # Plex thumb version tokens (the trailing id in the /thumb/<version> path),
        # used to cache resized posters and only regenerate when Plex changes the
        # art. NULL until the next scan repopulates them.
        if "preview_version" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN preview_version TEXT")
        if "show_preview_version" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN show_preview_version TEXT")
        # Playback resume point in seconds, written by the iOS player every
        # ~10s and on exit. 0 means "start from the beginning" — reaching the
        # end of a video resets it to 0, so a finished video never prompts.
        if "resume_secs" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN resume_secs REAL NOT NULL DEFAULT 0")
        # A video is either in a group or is a Plex item — never both, never
        # neither-but-meaningful. Nullability is the discriminator; there is no
        # `kind` column.
        if "group_id" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN group_id INTEGER REFERENCES groups(id)")
        if "plex_kind" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN plex_kind TEXT")
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
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                video_id INTEGER NOT NULL,
                version_id INTEGER NOT NULL DEFAULT 0,
                payload TEXT,
                result TEXT,
                priority INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'queued',
                attempts INTEGER NOT NULL DEFAULT 0,
                error_msg TEXT,
                created_at TEXT NOT NULL,
                started_at TEXT,
                finished_at TEXT
            );

            CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_pending
                ON jobs (kind, video_id, version_id)
                WHERE status IN ('queued', 'running');

            CREATE INDEX IF NOT EXISTS idx_jobs_claim ON jobs (status, priority, id);
            """
        )
        job_columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)").fetchall()}
        # Fraction 0..1 written by the converter process while ffmpeg runs. NULL
        # until a job is claimed; SQLite is the only channel between converter.py
        # and the web workers, which is why this lives on the row.
        if "progress" not in job_columns:
            _add_column(conn, "ALTER TABLE jobs ADD COLUMN progress REAL")
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                emoji TEXT,
                position INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """
        )
        group_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(groups)").fetchall()
        }
        # Per-group display setting: overlay each video's title on its player in
        # that group's view. Off for every existing group, which is what the
        # clients rendered before the column existed.
        if "display_titles" not in group_columns:
            _add_column(
                conn,
                "ALTER TABLE groups ADD COLUMN display_titles INTEGER NOT NULL DEFAULT 0",
            )
        _seed_default_groups(conn)
        _migrate_classifications_to_groups(conn)
        version_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(video_versions)").fetchall()
        }
        if "audio_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN audio_langs TEXT")
        if "converted_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN converted_langs TEXT")
        # JSON list of {language, name, default, forced}, filled once at scan
        # time by library.py's _probe_missing_subtitle_langs (mirrors
        # audio_langs). NULL means "not probed yet", not "no subtitles" — an
        # empty JSON array `[]` means the latter.
        if "subtitle_langs" not in version_columns:
            _add_column(conn, "ALTER TABLE video_versions ADD COLUMN subtitle_langs TEXT")
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
    group_id: int | None = None,
) -> int:
    with _conn() as conn:
        next_position = (conn.execute("SELECT MAX(position) FROM videos").fetchone()[0] or 0) + 1
        cur = conn.execute(
            """
            INSERT INTO videos (
                url, platform, source_key, title, preview_url, created_at, position, group_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                url,
                platform,
                source_key,
                title,
                preview_url,
                datetime.now(timezone.utc).isoformat(),
                next_position,
                group_id,
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
            SELECT id, audio_langs, subtitle_langs
            FROM video_versions
            WHERE video_id = ? AND id = ?
            """,
            (video_id, version_id),
        ).fetchone()
        if not row:
            return False
        conn.execute("UPDATE videos SET chosen_version_id = ? WHERE id = ?", (version_id, video_id))
        selected = conn.execute(
            "SELECT audio_lang, subtitle_lang FROM videos WHERE id = ?", (video_id,)
        ).fetchone()
        selected_lang = selected["audio_lang"]
        if selected_lang:
            try:
                available_langs = {
                    track.get("lang") for track in json.loads(row["audio_langs"] or "[]")
                }
            except (TypeError, ValueError):
                available_langs = set()
            if selected_lang not in available_langs:
                conn.execute("UPDATE videos SET audio_lang = NULL WHERE id = ?", (video_id,))
        selected_subtitle_lang = selected["subtitle_lang"]
        if selected_subtitle_lang:
            try:
                available_subtitle_langs = {
                    track.get("language")
                    for track in json.loads(row["subtitle_langs"] or "[]")
                }
            except (TypeError, ValueError):
                available_subtitle_langs = set()
            if selected_subtitle_lang not in available_subtitle_langs:
                conn.execute("UPDATE videos SET subtitle_lang = NULL WHERE id = ?", (video_id,))
        _sync_video_from_chosen(conn, video_id)
        return True


def set_audio_lang(video_id: int, lang: str) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET audio_lang = ? WHERE id = ?", (lang, video_id))


def set_subtitle_lang(video_id: int, lang: str | None) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET subtitle_lang = ? WHERE id = ?", (lang, video_id))


def set_resume_secs(video_id: int, secs: float) -> None:
    """Persist where playback got to. Negative input clamps to 0."""
    value = float(secs)
    if not math.isfinite(value):
        raise ValueError("resume seconds must be finite")
    value = max(0.0, value)
    with _conn() as conn:
        conn.execute("UPDATE videos SET resume_secs = ? WHERE id = ?", (value, video_id))


def set_version_audio_langs(version_id: int, audio_langs_json: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE video_versions SET audio_langs = ? WHERE id = ?",
            (audio_langs_json, version_id),
        )


def set_version_subtitle_langs(version_id: int, subtitle_langs_json: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE video_versions SET subtitle_langs = ? WHERE id = ?",
            (subtitle_langs_json, version_id),
        )


def _seed_default_groups(conn: sqlite3.Connection) -> None:
    """Seed the four starting groups, once, on a database that has none.

    Gated on emptiness rather than on the old `classification` column, so a
    brand-new install gets them too. Never re-runs: a user who deletes a group
    by hand does not get it resurrected on the next boot.
    """
    conn.execute("BEGIN IMMEDIATE")
    try:
        seeded = conn.execute(
            "SELECT 1 FROM sqlite_sequence WHERE name = 'groups'"
        ).fetchone()
        if not seeded and not conn.execute("SELECT 1 FROM groups LIMIT 1").fetchone():
            conn.executemany(
                "INSERT INTO groups (name, label, position) VALUES (?, ?, ?)",
                DEFAULT_GROUPS,
            )
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def _migrate_classifications_to_groups(conn: sqlite3.Connection) -> int:
    """Fold the old `classification` text column into `groups` + `plex_kind`."""
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    if "classification" not in columns:
        return 0

    placeholders = ",".join("?" for _ in PLEX_KINDS)
    conn.execute(
        "UPDATE videos SET group_id = ("
        "  SELECT groups.id FROM groups WHERE groups.name = videos.classification"
        f") WHERE classification IS NOT NULL AND classification NOT IN ({placeholders})",
        PLEX_KINDS,
    )
    conn.execute(
        f"UPDATE videos SET plex_kind = classification WHERE classification IN ({placeholders})",
        PLEX_KINDS,
    )
    unmatched = conn.execute(
        "SELECT COUNT(*) AS n FROM videos"
        " WHERE classification IS NOT NULL AND group_id IS NULL AND plex_kind IS NULL"
    ).fetchone()["n"]

    tables = {
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    }
    if "group_covers" in tables:
        conn.execute(
            "UPDATE groups SET emoji = ("
            "  SELECT emoji FROM group_covers WHERE group_covers.name = groups.name"
            ") WHERE EXISTS (SELECT 1 FROM group_covers WHERE group_covers.name = groups.name)"
        )
        conn.execute("DROP TABLE group_covers")

    conn.execute("ALTER TABLE videos DROP COLUMN classification")

    if unmatched:
        print(f"[migrate] {unmatched} video(s) had an unknown classification and are now unsorted")
    return unmatched


def list_groups() -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM groups ORDER BY position ASC, id ASC"
        ).fetchall()
        return [dict(r) for r in rows]


def get_group(group_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
        return dict(row) if row else None


def get_group_by_name(name: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM groups WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None


def create_group(
    name: str, label: str, emoji: str | None = None, position: int | None = None
) -> dict:
    """Raises sqlite3.IntegrityError when `name` is taken."""
    with _conn() as conn:
        if position is None:
            row = conn.execute("SELECT MAX(position) AS m FROM groups").fetchone()
            position = 0 if row["m"] is None else row["m"] + 1
        cur = conn.execute(
            "INSERT INTO groups (name, label, emoji, position) VALUES (?, ?, ?, ?)",
            (name, label, emoji, position),
        )
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (cur.lastrowid,)).fetchone()
        return dict(row)


def update_group(
    group_id: int,
    *,
    label: str | None = None,
    emoji: str | None = None,
    clear_emoji: bool = False,
    position: int | None = None,
    display_titles: bool | None = None,
) -> dict | None:
    """Partial update. `clear_emoji` is how a caller sets the emoji to NULL —
    `emoji=None` means "leave it alone", since that is what an omitted JSON
    field decodes to."""
    sets: list[str] = []
    params: list = []
    if label is not None:
        sets.append("label = ?")
        params.append(label)
    if clear_emoji:
        sets.append("emoji = NULL")
    elif emoji is not None:
        sets.append("emoji = ?")
        params.append(emoji)
    if position is not None:
        sets.append("position = ?")
        params.append(position)
    if display_titles is not None:
        sets.append("display_titles = ?")
        params.append(1 if display_titles else 0)
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return None
        if sets:
            sets.append("updated_at = CURRENT_TIMESTAMP")
            params.append(group_id)
            conn.execute(f"UPDATE groups SET {', '.join(sets)} WHERE id = ?", params)
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
        return dict(row)


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return _video_with_versions(conn, row)


def delete_video(video_id: int):
    with _conn() as conn:
        conn.execute("DELETE FROM video_versions WHERE video_id = ?", (video_id,))
        conn.execute("DELETE FROM videos WHERE id = ?", (video_id,))


def get_all_videos(
    group_id: int | None = None, plex_kind: str | None = None
) -> list[dict]:
    clauses = ["deleted_at IS NULL"]
    params: list = []
    if group_id is not None:
        clauses.append("group_id = ?")
        params.append(group_id)
    if plex_kind is not None:
        clauses.append("plex_kind = ?")
        params.append(plex_kind)
    sql = (
        f"SELECT * FROM videos WHERE {' AND '.join(clauses)}"
        " ORDER BY position DESC, created_at DESC"
    )
    with _conn() as conn:
        videos = [dict(r) for r in conn.execute(sql, params).fetchall()]
        _attach_versions(conn, videos)
    return videos


def _attach_versions(conn: sqlite3.Connection, videos: list[dict]) -> None:
    """Batch-load versions for the library rows in `videos` with two queries
    total, instead of the per-row pair `_video_with_versions` would issue (the
    N+1 that opened a fresh connection and file handle for every library row)."""
    library_ids = [v["id"] for v in videos if v.get("source") == "library"]
    if not library_ids:
        return

    placeholders = ",".join("?" for _ in library_ids)
    chosen = {
        row["id"]: row["chosen_version_id"]
        for row in conn.execute(
            f"SELECT id, chosen_version_id FROM videos WHERE id IN ({placeholders})",
            library_ids,
        ).fetchall()
    }
    versions_by_video: dict[int, list[dict]] = {vid: [] for vid in library_ids}
    for row in conn.execute(
        f"""
        SELECT *
        FROM video_versions
        WHERE video_id IN ({placeholders})
        ORDER BY position ASC, id ASC
        """,
        library_ids,
    ).fetchall():
        version = dict(row)
        version["is_chosen"] = version["id"] == chosen.get(version["video_id"])
        versions_by_video[version["video_id"]].append(version)

    for video in videos:
        if video.get("source") == "library":
            video["versions"] = versions_by_video[video["id"]]


def set_video_group(video_id: int, group_id: int | None) -> None:
    """Put a video in a group, or (with None) leave it unsorted.

    Setting a group clears Plex identity; clearing a group leaves it alone.
    """
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET group_id = ?, "
            "plex_kind = CASE WHEN ? IS NULL THEN plex_kind ELSE NULL END WHERE id = ?",
            (group_id, group_id, video_id),
        )


def set_video_plex_kind(video_id: int, kind: str | None) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET plex_kind = ?, "
            "group_id = CASE WHEN ? IS NULL THEN group_id ELSE NULL END WHERE id = ?",
            (kind, kind, video_id),
        )


def set_hls_status(video_id: int, status: str) -> None:
    """Track HLS package readiness: 'none' | 'converting' | 'done'."""
    with _conn() as conn:
        conn.execute("UPDATE videos SET hls_status = ? WHERE id = ?", (status, video_id))


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
        row = None
        if item.get("plex_rating_key"):
            row = conn.execute(
                "SELECT id, deleted_at FROM videos WHERE plex_rating_key = ?",
                (item["plex_rating_key"],),
            ).fetchone()
        # source_path is globally UNIQUE, so even when a rating-key lookup misses
        # (Plex reassigned the key, two items share a file, or a tombstoned row
        # still owns the path) we must match the existing row by path and UPDATE
        # it — a fall-through INSERT would hit the UNIQUE constraint.
        if row is None:
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
                SET url = ?, title = ?, plex_kind = ?, group_id = NULL, show_title = ?, season = ?,
                    episode = ?, summary = ?, plex_rating_key = ?, show_rating_key = ?,
                    preview_version = ?, show_preview_version = ?,
                    created_at = COALESCE(?, created_at),
                    position = COALESCE(?, position)
                WHERE id = ?
                """,
                (
                    item["source_path"],
                    item.get("title"),
                    item["plex_kind"],
                    item.get("show_title"),
                    item.get("season"),
                    item.get("episode"),
                    item.get("summary"),
                    item.get("plex_rating_key"),
                    item.get("show_rating_key"),
                    item.get("preview_version"),
                    item.get("show_preview_version"),
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
                url, title, status, plex_kind, source, source_path,
                show_title, season, episode, summary, plex_rating_key,
                show_rating_key, preview_version, show_preview_version,
                created_at, position
            )
            VALUES (?, ?, 'unconverted', ?, 'library', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                item["source_path"],
                item.get("title"),
                item["plex_kind"],
                item["source_path"],
                item.get("show_title"),
                item.get("season"),
                item.get("episode"),
                item.get("summary"),
                item.get("plex_rating_key"),
                item.get("show_rating_key"),
                item.get("preview_version"),
                item.get("show_preview_version"),
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


def clear_missing_conversion(version_id: int) -> None:
    """Revert a version to 'unconverted' after its converted file vanished from disk.

    Clears converted_path/langs so the next play reconverts, and re-syncs the parent
    video row when this is the chosen version. The stale 'done' status is what makes
    /stream serve a nonexistent file and 404; this undoes it.
    """
    with _conn() as conn:
        row = conn.execute(
            "SELECT video_id FROM video_versions WHERE id = ?", (version_id,)
        ).fetchone()
        if not row:
            return
        conn.execute(
            "UPDATE video_versions "
            "SET status = 'unconverted', converted_path = NULL, "
            "converted_langs = NULL, error_msg = NULL "
            "WHERE id = ?",
            (version_id,),
        )
        _sync_video_from_chosen(conn, row["video_id"])


def tombstone_missing_library_videos(seen_rating_keys: set[str]) -> int:
    """Tombstone live library rows whose Plex rating key vanished from the latest scan.

    Rows without a plex_rating_key are left alone (nothing to reconcile against);
    already-tombstoned rows are skipped. Returns the number newly tombstoned.
    """
    now = datetime.now(timezone.utc).isoformat()
    with _conn() as conn:
        rows = conn.execute(
            "SELECT id, plex_rating_key FROM videos "
            "WHERE source = 'library' AND deleted_at IS NULL "
            "AND plex_rating_key IS NOT NULL"
        ).fetchall()
        stale = [r["id"] for r in rows if r["plex_rating_key"] not in seen_rating_keys]
        for vid in stale:
            conn.execute(
                "UPDATE videos SET deleted_at = ? WHERE id = ?", (now, vid)
            )
        return len(stale)


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
    converted_langs: str | None = None,
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
                        converted_langs = COALESCE(?, converted_langs),
                        error_msg = ?
                    WHERE video_id = ? AND id = ?
                    """,
                    (status, converted_path, converted_langs, error_msg, video_id, version_id),
                )
                if error_msg and status == "unconverted":
                    conn.execute(
                        """
                        UPDATE video_versions
                        SET converted_path = NULL, converted_langs = NULL
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


def _job_row(row: sqlite3.Row | None) -> dict | None:
    """Rows out of the jobs table with payload/result decoded from JSON."""
    if row is None:
        return None
    job = dict(row)
    for field in ("payload", "result"):
        raw = job.get(field)
        try:
            job[field] = json.loads(raw) if raw else None
        except (TypeError, ValueError):
            job[field] = None
    return job


def enqueue_job(
    kind: str,
    video_id: int,
    version_id: int = 0,
    priority: int = PRIORITY_INTERACTIVE,
    payload: dict | None = None,
) -> int | None:
    """Queue ffmpeg work for converter.py. Returns None if it is already pending."""
    if kind not in JOB_KINDS:
        raise ValueError(f"Unknown job kind: {kind}")
    with _conn() as conn:
        cursor = conn.execute(
            """
            INSERT INTO jobs (kind, video_id, version_id, payload, priority, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            (
                kind,
                video_id,
                version_id,
                json.dumps(payload) if payload is not None else None,
                priority,
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        return cursor.lastrowid if cursor.rowcount else None


def claim_job() -> dict | None:
    """Atomically take the next eligible job. Skips jobs at MAX_JOB_ATTEMPTS."""
    with _write_conn() as conn:
        row = conn.execute(
            """
            UPDATE jobs
            SET status = 'running', started_at = ?, attempts = attempts + 1, progress = 0
            WHERE id = (
                SELECT id FROM jobs
                WHERE status = 'queued' AND attempts < ?
                ORDER BY priority, id LIMIT 1
            )
            RETURNING *
            """,
            (datetime.now(timezone.utc).isoformat(), MAX_JOB_ATTEMPTS),
        ).fetchone()
        return _job_row(row)


def finish_job(
    job_id: int, status: str, error_msg: str | None = None, result: dict | None = None
) -> None:
    with _conn() as conn:
        conn.execute(
            """
            UPDATE jobs
            SET status = ?, error_msg = ?, result = ?, finished_at = ?
            WHERE id = ?
            """,
            (
                status,
                error_msg,
                json.dumps(result) if result is not None else None,
                datetime.now(timezone.utc).isoformat(),
                job_id,
            ),
        )


# Kinds whose progress the iOS UI shows. 'normalize' is deliberately absent:
# those rows render as "downloading" in the app, not as a convert spinner.
PROGRESS_JOB_KINDS = ("convert", "hls")


def set_job_progress(job_id: int, fraction: float) -> None:
    """Record how far along a running job's ffmpeg is (0..1)."""
    with _conn() as conn:
        conn.execute("UPDATE jobs SET progress = ? WHERE id = ?", (fraction, job_id))


def active_jobs(queued_limit: int = 20) -> dict:
    """Running jobs, the next `queued_limit` queued ones, and the queued total.

    The queued slice uses claim_job's ordering, so it is genuinely the next work
    up. The cap exists because a bulk Download-all leaves 200+ rows queued and
    this feeds a 2s poll.
    """
    placeholders = ",".join("?" for _ in PROGRESS_JOB_KINDS)
    columns = """
        job.id, job.kind, job.video_id, job.version_id, job.priority, job.progress,
        video.title AS title, video.show_title AS show_title
    """
    with _conn() as conn:
        running = conn.execute(
            f"""
            SELECT {columns} FROM jobs AS job
            LEFT JOIN videos AS video ON video.id = job.video_id
            WHERE job.status = 'running' AND job.kind IN ({placeholders})
            ORDER BY job.id
            """,
            PROGRESS_JOB_KINDS,
        ).fetchall()
        queued = conn.execute(
            f"""
            SELECT {columns} FROM jobs AS job
            LEFT JOIN videos AS video ON video.id = job.video_id
            WHERE job.status = 'queued' AND job.attempts < ? AND job.kind IN ({placeholders})
            ORDER BY job.priority, job.id
            LIMIT ?
            """,
            (MAX_JOB_ATTEMPTS, *PROGRESS_JOB_KINDS, queued_limit),
        ).fetchall()
        total = conn.execute(
            f"""
            SELECT COUNT(*) FROM jobs
            WHERE status = 'queued' AND attempts < ? AND kind IN ({placeholders})
            """,
            (MAX_JOB_ATTEMPTS, *PROGRESS_JOB_KINDS),
        ).fetchone()[0]
    return {
        "running": [dict(row) for row in running],
        "queued": [dict(row) for row in queued],
        "queued_total": total,
    }


def requeue_job(job_id: int) -> None:
    """Return a job to the queue without decrementing its attempt count."""
    with _conn() as conn:
        conn.execute(
            "UPDATE jobs SET status = 'queued', started_at = NULL WHERE id = ?", (job_id,)
        )


def reset_orphan_jobs() -> list[dict]:
    """Requeue every running job and return the rows for temp-file cleanup."""
    with _write_conn() as conn:
        rows = conn.execute("SELECT * FROM jobs WHERE status = 'running'").fetchall()
        conn.execute(
            "UPDATE jobs SET status = 'queued', started_at = NULL WHERE status = 'running'"
        )
        return [_job_row(row) for row in rows]


def sweep_exhausted_jobs() -> int:
    """Fail queued jobs that have exhausted their claim attempts."""
    with _conn() as conn:
        cursor = conn.execute(
            """
            UPDATE jobs
            SET status = 'failed', error_msg = ?, finished_at = ?
            WHERE status = 'queued' AND attempts >= ?
            """,
            (
                f"gave up after {MAX_JOB_ATTEMPTS} attempts",
                datetime.now(timezone.utc).isoformat(),
                MAX_JOB_ATTEMPTS,
            ),
        )
        return cursor.rowcount


def recover_exhausted_convert_versions() -> int:
    """Atomically reset versions whose latest explicit convert job is exhausted."""
    recovered = 0
    with _write_conn() as conn:
        rows = conn.execute(
            """
            SELECT job.video_id, job.version_id, job.error_msg
            FROM jobs AS job
            JOIN video_versions AS version
              ON version.video_id = job.video_id
             AND version.id = job.version_id
            WHERE job.kind = 'convert'
              AND job.version_id > 0
              AND job.status = 'failed'
              AND job.attempts >= ?
              AND version.status = 'converting'
              AND NOT EXISTS (
                  SELECT 1
                  FROM jobs AS newer
                  WHERE newer.kind = job.kind
                    AND newer.video_id = job.video_id
                    AND newer.version_id = job.version_id
                    AND newer.id > job.id
              )
            ORDER BY job.id
            """,
            (MAX_JOB_ATTEMPTS,),
        ).fetchall()
        for row in rows:
            cursor = conn.execute(
                """
                UPDATE video_versions
                SET status = 'unconverted',
                    converted_path = NULL,
                    converted_langs = NULL,
                    error_msg = ?
                WHERE video_id = ? AND id = ? AND status = 'converting'
                """,
                (row["error_msg"], row["video_id"], row["version_id"]),
            )
            if cursor.rowcount:
                _sync_video_from_chosen(conn, row["video_id"])
                recovered += 1
    return recovered


def recover_jobless_converting_versions() -> int:
    """Free versions stuck at 'converting' with no pending convert job behind them.

    `/prepare` writes 'converting' before it enqueues, and short-circuits on
    that status, so a process that dies between the two lines strands the
    version forever: `recover_exhausted_convert_versions` can't see it (it
    joins jobs, and there is no job row), and the orphan reset only touches
    the jobs table. 226 versions sat this way after the 2026-07-31 incident.

    Only safe to call before the workers start, while nothing can be mid-claim.
    """
    recovered = 0
    with _write_conn() as conn:
        rows = conn.execute(
            """
            SELECT video_id, id FROM video_versions
            WHERE status = 'converting'
              AND NOT EXISTS (
                  SELECT 1 FROM jobs
                  WHERE jobs.kind = 'convert'
                    AND jobs.video_id = video_versions.video_id
                    AND jobs.version_id = video_versions.id
                    AND jobs.status IN ('queued', 'running')
              )
            ORDER BY video_id, id
            """
        ).fetchall()
        for row in rows:
            cursor = conn.execute(
                """
                UPDATE video_versions
                SET status = 'unconverted',
                    converted_path = NULL,
                    converted_langs = NULL,
                    error_msg = ?
                WHERE video_id = ? AND id = ? AND status = 'converting'
                """,
                ("interrupted before conversion started", row["video_id"], row["id"]),
            )
            if cursor.rowcount:
                _sync_video_from_chosen(conn, row["video_id"])
                recovered += 1
    return recovered


def queued_job_count() -> int:
    with _conn() as conn:
        return conn.execute("SELECT COUNT(*) FROM jobs WHERE status = 'queued'").fetchone()[0]


def get_job(job_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _job_row(row)
