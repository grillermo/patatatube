#!/usr/bin/env python3
"""Queue iPad 1 (SD) renditions for every finished video in one group.

    python sd_backfill.py children    # "videos musicales"

Only enqueues: converter.py does the encoding, FFMPEG_JOB_LIMIT at a time.
Safe to re-run — pending jobs and finished renditions are skipped.
"""
import sys

from dotenv import load_dotenv

load_dotenv()

import db  # noqa: E402
import sd  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python sd_backfill.py <group-name>", file=sys.stderr)
        return 2
    db.init_db()
    group = db.get_group_by_name(argv[1])
    if group is None:
        print(f"no group named {argv[1]!r}", file=sys.stderr)
        return 1
    queued, already = sd.enqueue_missing(group["id"], priority=sd.SD_BACKFILL_PRIORITY)
    print(f"{group['label']}: queued {queued}, already queued {already}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
