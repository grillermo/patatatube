import sqlite3
import os
import json
import math
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

# Seeded into `groups` on a fresh database. After that the table is the truth —
# this list is not consulted again and must never be imported as "the groups".
DEFAULT_GROUPS = [
    ("children", "Children", 0),
    ("adults", "Adults", 1),
    ("anabel", "Anabel", 2),
    ("asmr", "ASMR", 3),
]

# Where an upload lands when the client names no group. A staging group the
# user triages by hand, so it is looked up by name rather than pinned to an id
# or a position: renaming or reordering the groups must not silently retarget
# new downloads. Absent from the table, `/upload` falls back to the first group.
DEFAULT_UPLOAD_GROUP = "inbox"

# The group /sd plays until someone picks another. Looked up by name like
# DEFAULT_UPLOAD_GROUP, so renaming its label or reordering groups is harmless.
SD_DEFAULT_GROUP = "children"

JOB_KINDS = ("normalize", "sd")
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
        # Playback resume point in seconds, written by the iOS player every
        # ~10s and on exit. 0 means "start from the beginning" — reaching the
        # end of a video resets it to 0, so a finished video never prompts.
        if "resume_secs" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN resume_secs REAL NOT NULL DEFAULT 0")
        # NULL means unsorted.
        if "group_id" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN group_id INTEGER REFERENCES groups(id)")
        # The YouTube channel a download came from, captured at download time.
        # NULL for everything else, and for youtube rows downloaded before this
        # column existed until `POST /api/videos/backfill-channels` fills them.
        if "channel" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN channel TEXT")
        # How many times the video has been played, bumped by every playback
        # start. NULL is a third state and it matters: "not announced yet" --
        # a download still running. A group's badge counts the rows sitting at exactly 0 (announced,
        # never played), derived rather than stored, so it cannot drift, and the
        # count keeps rising long after the badge is gone. Replaces the `unread`
        # boolean this backfills from, whose 1 is this column's 0. Rows that were
        # never announced and never finished stay NULL so their download can
        # still announce them.
        if "play_count" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN play_count INTEGER")
            if "unread" in columns:
                conn.execute(
                    """
                    UPDATE videos SET play_count = CASE
                        WHEN unread = 1 THEN 0
                        WHEN status = 'done' THEN 1
                    END
                    """
                )
        if "unread" in columns:
            conn.execute("ALTER TABLE videos DROP COLUMN unread")
        # 1 once converter.py has written videos/{id}.sd.mp4, the iPad 1-safe
        # rendition /sd plays. Set only after the file is atomically in place.
        if "sd_ready" not in columns:
            _add_column(conn, "ALTER TABLE videos ADD COLUMN sd_ready INTEGER NOT NULL DEFAULT 0")
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
        # What the group is *for*, in the owner's words. The classifier reads it
        # instead of the label, which is too terse to separate groups that look
        # alike ("dormir" vs "videos musicales"). NULL falls back to the label.
        if "description" not in group_columns:
            _add_column(conn, "ALTER TABLE groups ADD COLUMN description TEXT")
        # Whether a stored `resume_secs` may produce a resume prompt for the
        # group's videos: a group video prompts only when its group has this on.
        # Position is recorded either way, so
        # switching it back on resumes where playback actually got to. It used
        # to be a per-video `videos.remember_position`: a group holding any
        # video that had it on starts on, and the old column is dropped.
        video_columns = {
            row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()
        }
        if "remember_position" not in group_columns:
            _add_column(
                conn,
                "ALTER TABLE groups ADD COLUMN remember_position INTEGER NOT NULL DEFAULT 0",
            )
            if "remember_position" in video_columns:
                conn.execute(
                    "UPDATE groups SET remember_position = 1 WHERE id IN "
                    "(SELECT group_id FROM videos WHERE remember_position = 1)"
                )
        if "remember_position" in video_columns:
            conn.execute("ALTER TABLE videos DROP COLUMN remember_position")
        # The UPDATE above opened an implicit transaction, and the seed below
        # starts its own BEGIN IMMEDIATE.
        conn.commit()
        _seed_default_groups(conn)
        _seed_sd_state(conn)
        _migrate_classifications_to_groups(conn)
        _purge_library(conn)
        _drop_hls(conn)
        _backfill_youtube_preview_urls(conn)
        _backfill_positions(conn)
        _delete_error_videos(conn)
        _run_one_shot_backfills(conn)


# Bumped only for a data backfill that is NOT naturally idempotent — one that
# would corrupt or discard good data if it ran twice. `PRAGMA user_version`
# records the last one applied. Schema changes still go in init_db as
# condition-guarded `ALTER TABLE`s; this is not a migrations framework.
SCHEMA_VERSION = 3


def _run_one_shot_backfills(conn: sqlite3.Connection) -> None:
    applied = conn.execute("PRAGMA user_version").fetchone()[0]
    if applied >= SCHEMA_VERSION:
        return

    # v1–v3 cleared video_versions.subtitle_langs; that table is gone (see
    # _purge_library). Add the next one-shot here as "if applied < 4:".

    conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")


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


_LIBRARY_COLUMNS = (
    "source_path", "converted_path", "show_title", "season", "episode", "summary",
    "plex_rating_key", "show_rating_key", "deleted_at", "chosen_version_id",
    "audio_lang", "subtitle_lang", "preview_version", "show_preview_version",
    "plex_kind", "source",
)


def _drop_hls(conn: sqlite3.Connection) -> None:
    """Remove HLS packaging's data. Idempotent.

    HLS was removed on 2026-11-21: every package was a `-c copy` of the mp4
    it came from, so its job kind and its status column go.
    """
    conn.execute("DELETE FROM jobs WHERE kind = 'hls'")
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    if "hls_status" in columns:
        conn.execute("ALTER TABLE videos DROP COLUMN hls_status")
    conn.commit()


def _purge_library(conn: sqlite3.Connection) -> int:
    """Remove the Plex Movies/TV feature's data. Idempotent: a database that
    never had it, or already lost it, passes straight through.

    Plex was uninstalled from the macmini on 2026-11-20 and the feature with
    it, so its rows, its job kind, its version table and every column only it
    wrote go. Downloads keep their resume position and play count.
    """
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    removed = 0
    if "source" in columns:
        library_ids = [
            row["id"]
            for row in conn.execute("SELECT id FROM videos WHERE source = 'library'").fetchall()
        ]
        if library_ids:
            placeholders = ",".join("?" for _ in library_ids)
            conn.execute(f"DELETE FROM jobs WHERE video_id IN ({placeholders})", library_ids)
            removed = conn.execute(
                f"DELETE FROM videos WHERE id IN ({placeholders})", library_ids
            ).rowcount
    conn.execute("DELETE FROM jobs WHERE kind = 'convert'")
    conn.execute("DROP TABLE IF EXISTS video_versions")
    # DROP COLUMN refuses a column an index still covers.
    conn.execute("DROP INDEX IF EXISTS idx_videos_source_path")
    for column in _LIBRARY_COLUMNS:
        if column in columns:
            conn.execute(f"ALTER TABLE videos DROP COLUMN {column}")
    conn.commit()
    if removed:
        print(f"[migrate] purged {removed} Plex library row(s)", flush=True)
    return removed


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


def set_resume_secs(video_id: int, secs: float) -> None:
    """Persist where playback got to. Negative input clamps to 0."""
    value = float(secs)
    if not math.isfinite(value):
        raise ValueError("resume seconds must be finite")
    value = max(0.0, value)
    with _conn() as conn:
        conn.execute("UPDATE videos SET resume_secs = ? WHERE id = ?", (value, video_id))


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


def _seed_sd_state(conn: sqlite3.Connection) -> None:
    """The /sd player's one row: selected group plus shuffle position.

    INSERT OR IGNORE, so a group picked on /sd survives every later boot; only
    the very first boot chooses SD_DEFAULT_GROUP (NULL when it does not exist).
    """
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS sd_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            group_id INTEGER,
            current_id INTEGER,
            played TEXT NOT NULL DEFAULT '[]'
        )
        """
    )
    conn.execute(
        "INSERT OR IGNORE INTO sd_state (id, group_id) "
        "VALUES (1, (SELECT id FROM groups WHERE name = ?))",
        (SD_DEFAULT_GROUP,),
    )


def _migrate_classifications_to_groups(conn: sqlite3.Connection) -> int:
    """Fold the old `classification` text column into `groups`. A classification
    that names no group (the old "tv"/"movies" ones included) leaves the video
    unsorted."""
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(videos)").fetchall()}
    if "classification" not in columns:
        return 0

    conn.execute(
        "UPDATE videos SET group_id = ("
        "  SELECT groups.id FROM groups WHERE groups.name = videos.classification"
        ") WHERE classification IS NOT NULL"
    )
    unmatched = conn.execute(
        "SELECT COUNT(*) AS n FROM videos"
        " WHERE classification IS NOT NULL AND group_id IS NULL"
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


# Announced (play_count IS NOT NULL) and never played. See init_db for why NULL
# is not the same as 0 here.
_UNPLAYED_WHERE = "play_count = 0 AND status = 'done'"


def list_groups() -> list[dict]:
    """Groups with their badge count. The alias is `unread_count` because that
    is the wire name `/api/groups` has always used and the one every installed
    build of the app decodes; the column behind it is `play_count` now."""
    with _conn() as conn:
        rows = conn.execute(
            f"""
            SELECT g.*,
                   (SELECT COUNT(*) FROM videos v
                    WHERE v.group_id = g.id AND {_UNPLAYED_WHERE}
                   ) AS unread_count
            FROM groups g
            ORDER BY g.position ASC, g.id ASC
            """
        ).fetchall()
        return [dict(r) for r in rows]


def unplayed_count(group_id: int) -> int:
    with _conn() as conn:
        return conn.execute(
            f"SELECT COUNT(*) FROM videos WHERE group_id = ? AND {_UNPLAYED_WHERE}",
            (group_id,),
        ).fetchone()[0]


def mark_announced(video_id: int) -> None:
    """Start counting plays for a video the user can now be told about.

    Called once, when a finished download is ready to be watched. `IS NULL`
    makes it idempotent in the direction that matters: a video that has already
    been played is never dragged back to 0 and re-badged. Moves never call this.
    """
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET play_count = 0 WHERE id = ? AND play_count IS NULL",
            (video_id,),
        )


def record_play(video_id: int) -> bool:
    """Count one play. True only when this was the play that cleared the badge.

    Every playback start calls this, so the count keeps climbing; only the
    0 -> 1 step changes a group's badge, and that is what the iOS client uses to
    decide whether refetching the group list is worth it. A play of a video that
    was never announced (NULL) counts too, but changes no badge.
    """
    with _conn() as conn:
        row = conn.execute(
            "SELECT play_count FROM videos WHERE id = ?", (video_id,)
        ).fetchone()
        if row is None:
            return False
        conn.execute(
            "UPDATE videos SET play_count = COALESCE(play_count, 0) + 1 WHERE id = ?",
            (video_id,),
        )
        return row["play_count"] == 0


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
    remember_position: bool | None = None,
    description: str | None = None,
    clear_description: bool = False,
) -> dict | None:
    """Partial update. `clear_emoji` is how a caller sets the emoji to NULL —
    `emoji=None` means "leave it alone", since that is what an omitted JSON
    field decodes to. `clear_description` does the same for the description."""
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
    if remember_position is not None:
        sets.append("remember_position = ?")
        params.append(1 if remember_position else 0)
    if clear_description:
        sets.append("description = NULL")
    elif description is not None:
        sets.append("description = ?")
        params.append(description)
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return None
        if sets:
            sets.append("updated_at = CURRENT_TIMESTAMP")
            params.append(group_id)
            conn.execute(f"UPDATE groups SET {', '.join(sets)} WHERE id = ?", params)
        row = conn.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
        return dict(row)


def delete_group(group_id: int, move_to: int) -> int | None:
    """Delete a group, moving its videos into `move_to` first so no row is left
    pointing at a group that no longer exists. Returns how many moved, or None
    when there is no such group. If /sd was playing it, /sd goes back to having
    no group selected rather than playing a dangling id."""
    with _conn() as conn:
        if not conn.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return None
        moved = conn.execute(
            "UPDATE videos SET group_id = ? WHERE group_id = ?", (move_to, group_id)
        ).rowcount
        conn.execute(
            "UPDATE sd_state SET group_id = NULL, current_id = NULL, played = '[]' "
            "WHERE group_id = ?",
            (group_id,),
        )
        conn.execute("DELETE FROM groups WHERE id = ?", (group_id,))
        return moved


def get_video(video_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM videos WHERE id = ?", (video_id,)).fetchone()
        return dict(row) if row else None


def delete_video(video_id: int):
    with _conn() as conn:
        conn.execute("DELETE FROM videos WHERE id = ?", (video_id,))


_SD_ELIGIBLE_WHERE = """
    WHERE group_id = ? AND status = 'done'
"""
_SD_ELIGIBLE = "FROM videos\n" + _SD_ELIGIBLE_WHERE


def get_sd_state() -> dict:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM sd_state WHERE id = 1").fetchone()
    if row is None:
        return {"group_id": None, "current_id": None, "played": []}
    return {
        "group_id": row["group_id"],
        "current_id": row["current_id"],
        "played": json.loads(row["played"] or "[]"),
    }


def save_sd_state(group_id: int | None, current_id: int | None, played: list[int]) -> None:
    with _conn() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO sd_state (id, group_id, current_id, played) "
            "VALUES (1, ?, ?, ?)",
            (group_id, current_id, json.dumps(played)),
        )


def sd_candidate_ids(group_id: int) -> list[int]:
    with _conn() as conn:
        rows = conn.execute(
            f"SELECT id {_SD_ELIGIBLE} AND sd_ready = 1 ORDER BY id", (group_id,)
        ).fetchall()
    return [row["id"] for row in rows]


def sd_pending_ids(group_id: int) -> list[int]:
    with _conn() as conn:
        rows = conn.execute(
            f"SELECT id {_SD_ELIGIBLE} AND sd_ready = 0 ORDER BY id", (group_id,)
        ).fetchall()
    return [row["id"] for row in rows]


def sd_counts(group_id: int) -> tuple[int, int]:
    """(eligible videos in the group, how many of them have an SD file)."""
    with _conn() as conn:
        row = conn.execute(
            f"SELECT COUNT(*) AS total, COALESCE(SUM(sd_ready), 0) AS ready {_SD_ELIGIBLE}",
            (group_id,),
        ).fetchone()
    return row["total"], row["ready"]


def set_sd_ready(video_id: int, ready: bool) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE videos SET sd_ready = ? WHERE id = ?", (1 if ready else 0, video_id)
        )


def clear_sd_ready(group_id: int) -> None:
    """Reset every SD-eligible row in a group back to not-ready, so a
    `--force` backfill re-queues all of them, not just the never-encoded
    ones."""
    with _conn() as conn:
        conn.execute(f"UPDATE videos SET sd_ready = 0 {_SD_ELIGIBLE_WHERE}", (group_id,))


def get_all_videos(group_id: int | None = None) -> list[dict]:
    sql = "SELECT * FROM videos"
    params: list = []
    if group_id is not None:
        sql += " WHERE group_id = ?"
        params.append(group_id)
    sql += " ORDER BY position DESC, created_at DESC"
    with _conn() as conn:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]


def set_video_group(video_id: int, group_id: int | None) -> None:
    """Put a video in a group, or (with None) leave it unsorted."""
    with _conn() as conn:
        conn.execute("UPDATE videos SET group_id = ? WHERE id = ?", (group_id, video_id))


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


def videos_missing_channel() -> list[dict]:
    """Completed YouTube rows downloaded before the channel was recorded.

    Ordered oldest-first so a backfill interrupted halfway resumes where it
    left off rather than re-walking the same head of the list.
    """
    with _conn() as conn:
        rows = conn.execute(
            """
            SELECT id, url FROM videos
            WHERE platform = 'youtube' AND status = 'done'
              AND channel IS NULL
            ORDER BY id
            """
        ).fetchall()
        return [dict(row) for row in rows]


def set_video_channel(video_id: int, channel: str) -> None:
    with _conn() as conn:
        conn.execute("UPDATE videos SET channel = ? WHERE id = ?", (channel, video_id))


def update_video(
    video_id: int,
    status: str,
    filename: str | None = None,
    error_msg: str | None = None,
    title: str | None = None,
    preview_url: str | None = None,
    channel: str | None = None,
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
                preview_url = COALESCE(?, preview_url),
                channel = COALESCE(?, channel)
            WHERE id = ?
            """,
            (status, filename, error_msg, title, preview_url, channel, video_id),
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


def set_job_progress(job_id: int, fraction: float) -> None:
    """Record how far along a running job's ffmpeg is (0..1)."""
    with _conn() as conn:
        conn.execute("UPDATE jobs SET progress = ? WHERE id = ?", (fraction, job_id))


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


def queued_job_count() -> int:
    with _conn() as conn:
        return conn.execute("SELECT COUNT(*) FROM jobs WHERE status = 'queued'").fetchone()[0]


def get_job(job_id: int) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _job_row(row)
