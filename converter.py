#!/usr/bin/env python3
"""The only process in PatataTube that spawns ffmpeg.

Web workers enqueue jobs; this drains them FFMPEG_JOB_LIMIT at a time. Before
this existed, every /prepare request spawned its own ffmpeg through a FastAPI
BackgroundTask -- 226 of them at once took the machine down on 2026-07-31.
See docs/superpowers/specs/2026-07-31-ffmpeg-job-queue-design.md.
"""
import argparse
import os
import signal
import threading
import time
import traceback
from pathlib import Path

import db
import hls
import library


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


FFMPEG_JOB_LIMIT = _positive_int_env("FFMPEG_JOB_LIMIT", 1)


def _handle_convert(job: dict, on_progress) -> None:
    version_id = job.get("version_id") or 0
    if version_id <= 0:
        raise ValueError("convert job requires a positive version_id")
    library.convert_library_video(
        job["video_id"], version_id, raise_errors=True, on_progress=on_progress
    )


def _handle_hls(job: dict, on_progress) -> None:
    payload = job.get("payload") or {}
    hls.prepare(job["video_id"], payload["source_path"], raise_errors=True, on_progress=on_progress)


def _handle_normalize(job: dict, on_progress) -> dict:
    # Imported lazily: downloader pulls in pybalt, which the other kinds do not
    # need, and a normalize job is rare compared to convert.
    from downloader import _normalize_media_for_ios_sync

    payload = job.get("payload") or {}
    output = _normalize_media_for_ios_sync(Path(payload["input_path"]))
    return {"output_path": str(output)}


JOB_HANDLERS = {
    "convert": _handle_convert,
    "hls": _handle_hls,
    "normalize": _handle_normalize,
}


def run_job(job: dict) -> None:
    """Dispatch one claimed job and record its outcome. Never raises."""
    started = time.monotonic()
    print(
        f"[job] +1 kind={job['kind']} id={job['video_id']} "
        f"priority={job['priority']} queued={db.queued_job_count()}",
        flush=True,
    )
    try:
        handler = JOB_HANDLERS.get(job["kind"])
        if handler is None:
            raise ValueError(f"Unknown job kind: {job['kind']}")
        result = handler(job, lambda fraction: db.set_job_progress(job["id"], fraction))
        db.finish_job(job["id"], "done", result=result)
        status = "done"
    except Exception as exc:  # noqa: BLE001 - a bad job must not kill the runner
        traceback.print_exc()
        db.finish_job(job["id"], "failed", error_msg=str(exc))
        status = "failed"
    print(
        f"[job] -1 kind={job['kind']} id={job['video_id']} "
        f"status={status} secs={time.monotonic() - started:.0f}",
        flush=True,
    )


def cleanup_orphan(job: dict) -> None:
    """Delete the partial output a crashed job left behind.

    Called at startup for every job still marked 'running'. Best-effort: a
    failure here must not stop the runner from draining the queue.
    """
    try:
        if job["kind"] == "convert":
            temp = library.temp_target_for(
                job["video_id"], version_id=job.get("version_id") or 0
            )
            if temp is not None:
                Path(temp).unlink(missing_ok=True)
        elif job["kind"] == "hls":
            hls.invalidate(job["video_id"])
        # normalize writes into the system temp dir, which the OS reaps.
    except Exception:  # noqa: BLE001
        traceback.print_exc()


def worker_loop(stop: threading.Event, poll_interval: float = 1.0) -> None:
    """Claim and run jobs until stopped. One thread per concurrent ffmpeg."""
    while not stop.is_set():
        job = db.claim_job()
        if job is None:
            stop.wait(poll_interval)
            continue
        run_job(job)


def recover_orphans() -> None:
    """Requeue crashed work, clean partials, and finalize exhausted versions."""
    orphans = db.reset_orphan_jobs()
    for orphan in orphans:
        print(f"[job] requeued orphan kind={orphan['kind']} id={orphan['video_id']}", flush=True)
        cleanup_orphan(orphan)

    swept = db.sweep_exhausted_jobs()
    db.recover_exhausted_convert_versions()

    if swept:
        print(f"[job] failed {swept} job(s) past {db.MAX_JOB_ATTEMPTS} attempts", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch-pid", type=int)
    parser.add_argument("--poll-interval", type=float, default=1.0)
    args = parser.parse_args()

    db.init_db()

    # Only this process runs jobs, so nothing can legitimately be 'running' at
    # our startup: anything still marked so is debris from a crash.
    recover_orphans()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    threads = [
        threading.Thread(target=worker_loop, args=(stop, args.poll_interval), daemon=True)
        for _ in range(FFMPEG_JOB_LIMIT)
    ]
    for thread in threads:
        thread.start()
    print(f"[job] converter up, limit={FFMPEG_JOB_LIMIT}", flush=True)

    # Exit when the parent dies, same contract as caddy_access.py --watch-pid.
    while not stop.is_set():
        if args.watch_pid is not None and not _process_exists(args.watch_pid):
            stop.set()
            break
        stop.wait(1.0)

    for thread in threads:
        thread.join(timeout=10)
    # Jobs still 'running' here were killed mid-flight; the next startup's
    # reset_orphan_jobs requeues them and cleans their temps.
    print("[job] converter down", flush=True)


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


if __name__ == "__main__":
    main()
