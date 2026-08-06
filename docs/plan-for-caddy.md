# Plan: Offload media byte-serving to Caddy (X-Accel-Redirect)

## Why

The FastAPI app currently streams every video byte itself: `stream_video` hand-rolls
Range parsing (`_parse_byte_range`), reads the file in 64 KB chunks through an async
generator (`_iter_file_range`), and gates concurrency with an asyncio semaphore
(`_video_stream_slots`, 16 slots). HLS segments and Plex-proxied previews go through
the same Python path. Each in-flight stream ties up an event-loop task, a file handle,
and a socket for the entire duration of playback.

That is the wrong job for the app. Byte-shuffling belongs in the web server, which does
it with `sendfile`/`io_uring`, native Range support, and kernel-managed backpressure —
no Python task per stream, far fewer file descriptors held open. This is the same "Too
many open files" pressure we just relieved by fixing the SQLite connection leak; this
change removes the *other* big FD/loop consumer.

**The app stays the auth + metadata brain.** It keeps validating the token, resolving
which file to serve, and gating readiness. It just stops copying the bytes: it returns
an empty `200` with an `X-Accel-Redirect` header naming the file, and Caddy serves it.
The client can never set that header — Caddy only reads it from the *upstream response* —
so `secrets.compare_digest` remains the sole gate. Security is unchanged.

## Current deployment topology

- Caddy runs on the host (`~/c/server/Caddyfile`), listening on plain HTTP ports.
- Cloudflare Tunnel maps each public hostname to a local Caddy port.
- House style per app: `handle /public/*` → `file_server`, `handle` → `reverse_proxy`
  to the app (often blue/green with `/health` checks), plus a rolling access log.
- PatataTube is **not yet in that Caddyfile**. The tunnel for
  `videos.chiq.me` / `patatatube.chiq.me` currently points straight at uvicorn on
  `:3050`. This plan inserts a Caddy block in front, matching the existing style.

## Target architecture

```
Cloudflare Tunnel ──▶ Caddy :3050  ──┬─ /videos/{id}/stream   ─┐
                                     ├─ /videos/{id}/hls/*     ─┤ reverse_proxy → uvicorn :3055
                                     ├─ /videos/{id}/preview   ─┤   (auth + resolve + X-Accel-Redirect)
                                     │                          │
                                     │   handle_response @accel │
                                     │   ┌──────────────────────┘
                                     └──▶ file_server from internal roots  (bytes, Range, sendfile)
                                     
                                     └─ everything else ───────▶ reverse_proxy → uvicorn :3055  (HTML/JSON)
```

Uvicorn moves off the public port (to `:3055`); Caddy takes `:3050` so the existing
tunnel mapping is untouched.

### Four file roots Caddy must reach

| Content            | On-disk location                              | Emitted redirect prefix |
|--------------------|-----------------------------------------------|-------------------------|
| Download videos    | `<repo>/videos/{id}.mp4`                       | `/_protected/videos/`   |
| HLS packages       | `<repo>/data/hls/{id}/…`                        | `/_protected/hls/`      |
| Previews (Plex)    | `<repo>/data/previews/{rating_key}.jpg`        | `/_protected/previews/` |
| Library media      | arbitrary Plex paths, e.g. `/Volumes/Media/…`  | `/_protected/media/`    |

The first three live under the repo. Library sources (and their sibling `.mp4`
conversions) live wherever Plex mounts them, so they get their own root anchored at the
media mount (`MEDIA_ROOT`, default `/Volumes/Media`). The app emits a path *relative to*
that root; Caddy rejoins it. Nothing outside the declared roots is reachable.

## Caddyfile block (add to `~/c/server/Caddyfile`)

```caddyfile
# patatatube
:3050 {
	# App authorizes and resolves the file, then hands back an X-Accel-Redirect.
	# Caddy serves the named bytes from the matching internal root below.
	reverse_proxy localhost:3055 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}

		@accel header X-Accel-Redirect *
		handle_response @accel {
			# strip the /_protected prefix, then map each subtree to its root
			@videos   path /_protected/videos/*
			handle @videos {
				root    * /Users/grillermo/c/patatatube/videos
				rewrite * {rp.header.X-Accel-Redirect}
				uri     strip_prefix /_protected/videos
				method  GET
				file_server
			}

			@hls path /_protected/hls/*
			handle @hls {
				root    * /Users/grillermo/c/patatatube/data/hls
				rewrite * {rp.header.X-Accel-Redirect}
				uri     strip_prefix /_protected/hls
				method  GET
				file_server
			}

			@previews path /_protected/previews/*
			handle @previews {
				root    * /Users/grillermo/c/patatatube/data/previews
				rewrite * {rp.header.X-Accel-Redirect}
				uri     strip_prefix /_protected/previews
				method  GET
				file_server
			}

			@media path /_protected/media/*
			handle @media {
				root    * /Volumes/Media
				rewrite * {rp.header.X-Accel-Redirect}
				uri     strip_prefix /_protected/media
				method  GET
				file_server
			}
		}
	}

	log {
		output file /Users/grillermo/c/patatatube/logs/caddy_access.log {
			roll_size 100mb
			roll_keep 10
			roll_keep_for 7d
		}
	}
}
```

Notes:
- `file_server` gives Range/206, `Accept-Ranges`, conditional GETs, and `sendfile` for
  free — deletes the need for `_parse_byte_range` / `_iter_file_range` / the semaphore.
- Blue/green (two upstreams + `health_uri /health`) can be layered on later exactly like
  the other apps; start single-upstream.
- Caddy sets `Content-Type` by extension; keep the app's cache headers by having the app
  set them and Caddy pass them through, or set them here with `header`.

## App changes (`router.py`, behind a flag)

Gate on `USE_XACCEL` (env, default off) so the pure-Python path stays as fallback and
rollback is a single env var.

1. **`stream_video`** — after auth + readiness + existence checks, when `USE_XACCEL`:
   return `Response(status_code=200, headers={"X-Accel-Redirect": _protected_path(file_path), "Cache-Control": VIDEO_CACHE_CONTROL})`
   instead of building the `StreamingResponse`. No Range parsing in Python — Caddy does it.
   (Keep the "video uploaded" completion log by moving it to an access-log grep, or drop
   it; the generator that emitted it is gone on this path.)
2. **`hls_asset`** — when the asset exists on disk and `USE_XACCEL`, return the
   `X-Accel-Redirect` to `/_protected/hls/{id}/{asset_path}` instead of `FileResponse`.
   The 409 "preparing" path and the background-task trigger are unchanged.
3. **`video_preview`** — when the cache file exists and `USE_XACCEL`, redirect to
   `/_protected/previews/{rating_key}.jpg`. The Plex fetch-and-cache miss path is
   unchanged (still writes the file, then can redirect).
4. **New helper `_protected_path(file_path) -> str`** — classify the resolved path into
   one of the four prefixes: under `VIDEOS_DIR` → `/_protected/videos/…`; under
   `HLS_DIR` → `/_protected/hls/…`; under `PREVIEWS_DIR` → `/_protected/previews/…`;
   otherwise treat as media and emit `/_protected/media/<path relative to MEDIA_ROOT>`.
   URL-encode path segments. If a library path falls outside `MEDIA_ROOT`, fall back to
   the Python `StreamingResponse` (don't emit an unreachable redirect).
5. Once verified in prod, delete `_parse_byte_range`, `_iter_file_range`,
   `_video_stream_slots`, `VIDEO_CHUNK_SIZE`, `DEFAULT_VIDEO_STREAM_LIMIT` — dead code.

Auth stays first in every handler; `X-Accel-Redirect` is only emitted *after* the token
check passes.

## `serve` changes (required)

The `serve` script must change so Caddy fronts the app:

1. **Bind to the internal port, not the public one.** Default `PORT` becomes `3055`
   (Caddy owns `3050`). Add `APP_PORT="${APP_PORT:-3055}"` and use it in both the dev and
   prod `exec` lines. Keep `PORT` overridable for the no-Caddy fallback.
2. **Bind loopback in production.** Change `--host 0.0.0.0` → `--host 127.0.0.1` for the
   prod worker path: only Caddy (same host) should reach uvicorn now. Dev/`DEV=1` can
   stay `0.0.0.0` for LAN testing.
3. **Add a `/health` endpoint** to the app (returns `{"ok": true}`) so the Caddy block
   can later adopt the blue/green `health_uri /health` pattern used by the other apps;
   wire it into `serve`'s comment block documenting the topology.
4. **Keep the `ulimit -n` line** already added — still useful; Caddy removes most stream
   FDs but downloads (ffmpeg/yt-dlp) and SQLite remain.
5. **Set `USE_XACCEL=1`** in the prod `exec` environment (or `.env`) once the Caddy block
   is live; leave it unset for local runs without Caddy.
6. Update the header comment in `serve` to document the new two-tier topology
   (Caddy :3050 public → uvicorn :3055 loopback) so the port split isn't surprising.

Sketch of the relevant prod line after the change:

```bash
APP_PORT="${APP_PORT:-3055}"
exec env USE_XACCEL="${USE_XACCEL:-1}" "$PYTHON_BIN" -m uvicorn main:app \
  --host 127.0.0.1 \
  --port "$APP_PORT" \
  --workers "${WEB_CONCURRENCY:-2}" \
  --proxy-headers \
  --forwarded-allow-ips='*'
```

`--proxy-headers` / `--forwarded-allow-ips` stay (now honoring Caddy's `X-Forwarded-*`).

## Phases

1. **App: add flag + helper + health, no behavior change with flag off.** Ship
   `_protected_path`, the three redirect branches, `/health`, all behind `USE_XACCEL`.
   Existing tests still pass (flag defaults off). Add tests asserting: with the flag on,
   each endpoint returns `200` + correct `X-Accel-Redirect` and no body; auth failures
   still `401` *before* any redirect header is set.
2. **`serve`: port split + loopback + env.** Move app to `:3055`, bind loopback, document.
3. **Caddyfile: add the block**, `caddy reload`, point/keep the tunnel at `:3050`.
4. **Verify in prod** (see below). Flip `USE_XACCEL=1`.
5. **Cleanup:** delete the dead Python streaming code once a week of prod traffic is clean.

## Verification

- `curl -H "Range: bytes=0-1023" .../stream?token=…` → `206`, `Content-Range`,
  1024 bytes. Compare byte-for-byte against the pre-change response.
- HLS: load a library video in the iPad app / Safari; confirm master + segments + subs
  play, seeking works (Range).
- Preview grid loads; `/videos/{id}/preview` returns the JPEG with cache headers.
- **FD check** (the whole point): `lsof -p <uvicorn worker> | grep -c videos` stays ~0
  during active playback of several streams; total FDs flat. Under the old path each
  stream held a file handle for its full duration.
- 404/401 paths: bad token → `401` with no `X-Accel-Redirect`; missing file → `404`;
  not-ready → `409`. Caddy must never serve a file the app didn't authorize.
- Path-traversal: request `/videos/{id}/hls/../../etc/passwd` style — app's
  `hls.safe_asset_path` already rejects; confirm the redirect is never emitted for it.

## Risks & rollback

- **Rollback is one env var:** unset `USE_XACCEL`, `serve` restart → back to the Python
  streaming path. Caddy block can stay (it only acts on the `X-Accel-Redirect` header,
  which the app stops sending).
- **Arbitrary library paths outside `MEDIA_ROOT`** would produce an unreachable redirect;
  the `_protected_path` fallback to `StreamingResponse` covers that case. Audit
  `source_path` values before flipping the flag.
- **Header leakage:** ensure the app does not forward `X-Accel-Redirect` from any
  *client* input; it is only ever server-generated. (Caddy reads it from the upstream
  response, not the client request, so client injection is already impossible.)
- **Content-Type / cache headers** now partly set by Caddy — verify the iPad player and
  PWA still get `video/mp4` and the immutable cache policy.

## Out of scope (follow-ups)

- Blue/green for PatataTube (mirror the yosubee/antesis `reverse_proxy` health-check
  block once `/health` exists).
- Moving `db.*` calls off the event loop (sync SQLite inside `async def`); orthogonal to
  this change but the next biggest event-loop stall.
