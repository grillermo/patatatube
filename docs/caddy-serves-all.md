# Caddy serves library videos too (symlink approach)

## Problem

Streaming is capped at ~20 MB/s for library videos (movies/TV), even on local
5GHz WiFi next to a router wired to the server. Not a network limit: `iperf3`
hits 100 MB/s, and raw disk read of the source file is ~980 MB/s (local exFAT
`/Volumes/Media`).

The cap is the **Python streaming path**. Caddy already intercepts and serves
*download* videos natively (`videos/{id}.mp4` under its root), but *library*
videos fall through to FastAPI/gunicorn and get streamed by `_iter_file_range`
(anyio thread-pool chunked reads). Measured: iOS opens 4 parallel range
requests, each ~6.2 MB/s → ~24 MB/s aggregate.

### Why download videos hit Caddy but library videos don't

Caddyfile `@stream` block does `try_files /videos/{id}.mp4`. Download videos
live exactly there, so Caddy's `file_server` serves them (native sendfile +
Range). Library videos live at arbitrary paths like
`/Volumes/Media/media/movies/<title>/<file>.mp4`, known **only to SQLite**
(`video_versions.converted_path`). The URL `/videos/62/stream?version_id=27`
carries no file path, and Caddy can't query the DB to resolve one — so it falls
through to the app. Not a permissions issue: Caddy runs as the user and can read
`/Volumes/Media` fine.

## Idea: symlink library files into `videos/`

Give Caddy a URL→file mapping it *can* express as a rewrite, by placing
symlinks under the existing `videos/` root pointing at the real files on
`/Volumes/Media`.

- **Symlinks, not hardlinks.** Hardlinks can't cross filesystems; `videos/` is
  on internal APFS, media on exFAT `/Volumes/Media` (different devices).
  Caddy's `file_server` follows symlinks by default.

### Sketch

1. **Link naming.** Library streams carry `?version_id=`. Create
   `videos/{video_id}-v{version_id}.mp4` per converted version (and optionally
   `videos/{video_id}.mp4` → default version). Caddyfile gains a `try_files`
   using the query placeholder `{http.request.uri.query.version_id}`.
2. **Only converted mp4s.** Unconverted versions fall back to a raw `.mkv`
   `source_path` — wrong container/mime, unplayable on iOS. Only link where
   `converted_path` exists; everything else keeps falling through to Python.
3. **Lifecycle.** Create link at convert-completion and during `scan_library`
   backfill; remove on tombstone delete and on re-conversion. Recreating links
   during every scan keeps disk state from drifting from the DB.
4. **Staleness handled for free.** Caddy stats the symlink *target*, so ETag /
   Last-Modified / If-Range update automatically when the file changes.
5. **Unmounted volume.** Broken symlink → `try_files` misses → falls through to
   Python → graceful 404, same degradation as today.
6. **No namespace clash.** Download videos already use bare `{id}.mp4` in
   `videos/`; ids share one sequence in one table, so no filename collision.

### Cost

~30 lines in `library.py` (create/remove links) + a small `try_files` addition
in the Caddyfile. No changes to the app's streaming code.

### Weakness

Duplicates state on disk (symlinks) that can drift from the DB. Mitigated by
recreating links on every `scan_library`.

## Alternative considered: X-Accel-Redirect

App answers with the file path in a response header (e.g. `X-File-Path`); Caddy
`reverse_proxy` + `handle_response` intercepts, rewrites to that path, and
serves it natively. No on-disk symlink state to drift, but needs app streaming
changes and Caddyfile response-interception plumbing. Symlinks preferred for
simplicity.

## Verified facts (2026-07-23)

- `iperf3`: ~100 MB/s over the WiFi link.
- `dd` of the Totoro source mp4 on `/Volumes/Media`: 983 MB/s.
- Caddy access log: download video (id 563/599) GET `/stream` →
  `served_by: caddy`. Library video (id 62, `?version_id=27`) GET `/stream` →
  `served_by` absent (reverse-proxied to Python), 1.2 GB range in ~196 s
  (~6.2 MB/s), 4 parallel connections.
- `/Volumes/Media` = `/dev/disk6s1`, exFAT, local.
