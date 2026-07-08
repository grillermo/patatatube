"""One-shot migration: re-label every existing multi-version library video via the LLM.

Standalone on purpose (not init_db): it hard-fails on any LLM error, and we never
want a missing key or an OpenAI outage to brick app startup. Run manually:

    python relabel_versions.py            # apply
    python relabel_versions.py --dry-run  # preview old -> new, write nothing

One LLM call per video (order preserved 1:1 with the version list).
"""
import sys

from dotenv import load_dotenv

import db
import version_namer
from pathlib import Path


def _multiversion_videos(conn):
    return conn.execute(
        """
        SELECT v.id, v.title
        FROM videos v
        JOIN video_versions vv ON vv.video_id = v.id
        WHERE v.source = 'library'
        GROUP BY v.id
        HAVING COUNT(vv.id) >= 2
        ORDER BY v.id
        """
    ).fetchall()


def main(dry_run: bool = False) -> int:
    load_dotenv()
    db.init_db()
    updated = 0
    with db._conn() as conn:
        videos = _multiversion_videos(conn)
        print(f"{len(videos)} multi-version library video(s) to relabel")
        for video in videos:
            versions = conn.execute(
                """
                SELECT id, source_path, label
                FROM video_versions
                WHERE video_id = ?
                ORDER BY position ASC, id ASC
                """,
                (video["id"],),
            ).fetchall()
            labels = version_namer.label_versions(
                [Path(v["source_path"]).name for v in versions]
            )
            print(f"\n#{video['id']} {video['title']!r}")
            for version, label in zip(versions, labels):
                print(f"  {version['label']!r} -> {label!r}")
                if not dry_run:
                    conn.execute(
                        "UPDATE video_versions SET label = ? WHERE id = ?",
                        (label, version["id"]),
                    )
            updated += 1
    print(f"\n{'Would update' if dry_run else 'Updated'} {updated} video(s)")
    return updated


if __name__ == "__main__":
    main(dry_run="--dry-run" in sys.argv)
