# Spotify track links, recorded through librespot's pipe sink

Date: 2026-10-17
Status: draft, awaiting review

## Intent

Paste a Spotify track link into PatataTube (the iOS share sheet, the web page,
`/save_video`) and get that song in a group, playable like any other video.
The user has Spotify Premium and wants the audio recorded **straight from
Spotify** through librespot, not matched against YouTube. They accept that this
breaks Spotify's terms and that the account may be flagged or banned.

One song at a time, in both senses: a link names one track, and the server never
records two tracks at once.

## Goals

- `POST /upload` (and so every client) accepts a Spotify track link and stores
  the song as a normal download row: queued → downloading → done, in a group,
  with a badge, HLS and an SD rendition like any other video.
- Audio comes from Spotify itself at 320 kbps (Premium), decoded by librespot
  and written by its `pipe` sink.
- Title, artist and album come from Spotify's own metadata, and the album
  cover is what you see on the card and the player.
- A one-time login on the macmini, and recordings need nothing from the user
  after that.

## Non-goals

- Albums, playlists, artists, shows, podcasts. Those links get a 400. (Albums
  and playlists could later follow `import_playlist`'s sequential pattern.)
- `spotify.link/…` short links. They need a network round trip to resolve, and
  the share sheet gives `open.spotify.com` links. Not now.
- Spotify Connect, playback control, or anything in spotatui's feature set.
  spotatui has no download feature at all; we use the same librespot crates,
  not the spotatui app.
- A UI for logging in. It is a one-time CLI step.
- Lossless or bit-exact copies. The audio is decoded and then encoded again
  (Vorbis → PCM → AAC), which is fine.

## Anti-goals (a failure even if it "works")

- **A truncated or silent song saved as done.** A recording shorter than the
  track, or all zeros, is a failure. librespot is known to go silent on some
  CDN errors (the reason spotatui maintains a fork).
- **Two recordings at once**, across gunicorn workers too. That looks like
  account sharing to Spotify, and the user asked for one at a time.
- **ffmpeg spawned outside `converter.py`.** That invariant stays (CLAUDE.md,
  "ffmpeg runs in exactly one process").
- **Spotify credentials in the repo, the logs, or a job payload.**

## Context: what librespot gives us (checked 2026-10-17, librespot `dev` @ 1995951, 0.8.0)

- The `librespot` binary is Connect-only: it waits to be picked as a device. It
  cannot be told "play this one track", so we need a small Rust program built
  on the librespot crates. `examples/play.rs` is almost exactly that program:
  `Session::connect(credentials)` → `Player::new(config, session, NoOpVolume,
  || backend(device, format))` → `player.load(SpotifyUri::Track{id}, true, 0)`
  → `player.await_end_of_track()`.
- The `pipe` backend (`StdoutSink`, `playback/src/audio_backend/pipe.rs`)
  writes raw samples to stdout, or with a device string to a file it truncates
  on `start()`. Default `AudioFormat` is S16 little-endian, 44100 Hz
  (`SAMPLE_RATE`), 2 channels (`NUM_CHANNELS`).
- `PlayerConfig.bitrate` takes `Bitrate320`. `normalisation` defaults to off,
  which is what we want (no volume changes).
- Player events include `EndOfTrack` and `Unavailable`. `Unavailable` covers
  region locks and removed tracks.
- Login: password login is gone. Auth is OAuth. `librespot-oauth` has a
  **device-code flow** (`request_device_code` / `poll_for_token`, the same
  pairing-page flow spotatui uses), which suits a headless server.
  `Credentials::with_access_token` connects, and `Cache::save_credentials` /
  `Cache::credentials` store and reload the reusable credentials the session
  hands back, so only the first run needs a browser.
- The pipe sink does not wait for a clock. It is expected to run faster than
  real time, but **this is unverified**: the spike measures it. Real time
  (≈ song length per recording) is acceptable.

## Design

### 1. `tools/spotify-recorder/`: a Rust service that runs in `./serve`

A Cargo project in the repo with two subcommands:

```
spotify-recorder serve --cache <dir> --listen 127.0.0.1:<port>
spotify-recorder login --cache <dir>
```

**`serve`** is a long-running process, its own pane in `./serve` like caddy,
convert and web (section 7). It holds **one** librespot `Session` for its whole
life and reconnects it when it drops. Unlike a session per song, that means one
login per server start, which looks less like a bot to Spotify. It listens on
localhost only and serves a tiny HTTP API (the builder picks the crate; axum is
the obvious one):

- `POST /record` with `{"track": "<base62 id>", "out": "<absolute .pcm path>"}`.
  It fetches the track's metadata with `librespot-metadata`, plays the track
  into the pipe sink with `out` as the device, at 320 kbps with normalisation
  off, and waits for `EndOfTrack`. The response comes only after the recording
  is finished:

  ```json
  {"id":"4uLU6hMCjMI75M1A2tKUQC","title":"Never Gonna Give You Up",
   "artists":["Rick Astley"],"album":"Whenever You Need Somebody",
   "duration_ms":213573,"cover_url":"https://i.scdn.co/image/…",
   "pcm_bytes":37676000,"sample_rate":44100,"channels":2,"format":"s16le"}
  ```

  Errors: **404** unavailable (an `Unavailable` event or no audio file), **401**
  not logged in or credentials rejected (body says to run `login`), **500**
  anything else. Each has a JSON `{"error": "..."}`.
- **One at a time is enforced here.** Recording sits behind a single async
  mutex, so concurrent requests queue inside the service, in arrival order, and
  the session never plays two tracks at once. The whole server sends its
  recordings to this one process, so that covers every gunicorn worker.
- `GET /health` returns `{"logged_in": bool, "recording": "<id>"|null}`.
- If there are no cached credentials at startup, it still starts and answers
  `401` to `/record`. After a `login`, it loads the new credentials on the next
  request, with no restart needed.
- Logs go to stdout, one line per event (`record <id> start`,
  `record <id> done secs=N bytes=N`, failures). The pane labels them and
  mirrors them into `log/backend.log`. Never tokens.

**`login`** runs device-code OAuth: it prints the verification URL and user
code, polls until you confirm, connects once, and saves the reusable credentials
in `<dir>`. It is run by hand on the macmini once, and again only if Spotify
revokes the login. It works while `serve` is running.
- **Crates:** the spotatui fork, `spotatui-librespot-*` `=0.8.6` with the
  `package =` rename that spotatui's `Cargo.toml` uses. It is upstream 0.8 plus
  the CDN-530 fallback for silent playback, which is our anti-goal. Only the
  `pipe` backend is used, so build `librespot-playback` with no audio-device
  backend features. *(My call; the builder can switch to upstream `librespot`
  0.8 if the fork gives trouble.)*
- The cover URL is the largest album image from the metadata, as
  `https://i.scdn.co/image/<file id hex>`.

### 2. Configuration

Env, read the way `YTDLP_BIN` and friends are:

| Var | Default | Meaning |
|---|---|---|
| `SPOTIFY_RECORDER_BIN` | `tools/spotify-recorder/target/release/spotify-recorder` | the binary |
| `SPOTIFY_RECORDER_PORT` | `3052` | the `serve` port on 127.0.0.1 (web is 3051, Caddy 3050) |
| `SPOTIFY_CACHE_DIR` | `data/spotify` | credentials; under gitignored `data/`, never on `MEDIA_ROOT` |
| `SPOTIFY_RECORD_TIMEOUT` | `900` (seconds) | the client-side timeout for one `/record`, queue wait included |

`.env.example` documents them, and `./serve` adds them to `FORWARD_VARS`. If
the service is down (connection refused), the download fails with a log line
naming the `spotify` pane.

### 3. URL classification (`router._classify_url`)

A new `spotify` platform, tried before YouTube:

- `https://open.spotify.com/track/<id>`, with or without `/intl-xx/`, with any
  query (`?si=…`) → `{"platform": "spotify", "source_key": <id>,
  "normalized_url": "https://open.spotify.com/track/<id>"}`.
- `spotify:track:<id>` → the same.
- `<id>` must be 22 base62 characters.
- Any other `open.spotify.com` path (album, playlist, artist, episode, show) →
  **400** "Only Spotify track links are supported".

`upload` treats it like `youtube`: a completed `spotify` row with the same
`source_key` is moved into the requested group and its id is returned
(`get_completed_video_by_source("spotify", …)`), so the same song is never
recorded twice. `preview_url` starts as NULL. The classify-when-no-group rule is
unchanged.

### 4. Downloading (`downloader.download_video`)

A `spotify` branch, shaped like the YouTube one:

1. Make a temp `.pcm` path. Use the system temp dir, which is the same machine
   as the service.
2. `POST http://127.0.0.1:$SPOTIFY_RECORDER_PORT/record` with an
   `httpx.AsyncClient(trust_env=False, timeout=SPOTIFY_RECORD_TIMEOUT)`. This
   is a plain async await, so no thread is held while the request waits its
   turn in the service's queue, and the row stays `downloading` meanwhile.
3. **Validate**, and fail (row deleted, as for every failed download) when:
   - the response is not 200, or the connection fails;
   - the PCM duration (`pcm_bytes / (44100 × 2 × 2)`) differs from
     `duration_ms` by more than 2 s;
   - the audio is silent: the builder picks a cheap check, e.g. the RMS of
     sampled windows under a small threshold over the whole file.
4. Write `title`, `channel` = the artists joined with `", "`, and `preview_url`
   = `cover_url` onto the row. Then, if `classify`, call
   `services.classify_download` with the duration and **no description**,
   exactly as the YouTube branch does.
5. Download the cover (httpx, `trust_env=False`) to a temp file. If it fails,
   go on without one (see 5).
6. Enqueue the ffmpeg work as a **new converter job kind, `spotify`** (below),
   wait for it like `_normalize_media_for_ios` waits for `normalize`, and move
   the result to `videos/{id}.mp4`.
7. Then the usual tail: `status="done"`, `filename`, the `hls` job,
   `_announce_new_video`, `sd.enqueue_if_selected`. Temp PCM and cover files are
   removed on every path.

The service is busy only during step 2. Validation and ffmpeg run after it
answers, so the next track can start recording.

If the service is restarted mid-recording (`./serve` rerun, crash), the request
gets a connection error and the row is deleted, the same as any failed download.
Recordings are not resumed. Downloads are BackgroundTasks and are not durable
today either.

### 5. The `spotify` converter job

`_normalize_media_for_ios_sync` refuses files with no video stream, and HLS,
the grid players and the SD rendition all assume one. So the song becomes a
**video whose picture is the album cover**, which keeps every downstream path
unchanged.

Payload: `pcm_path`, `cover_path` (nullable), `title`, `artist`, `album`,
`source_key`. ffmpeg inputs: `-f s16le -ar 44100 -ac 2 -i <pcm>` plus
`-loop 1 -framerate <low> -i <cover>`. With no cover, use a solid `#111111`
`color` source. Output:

- H.264, `yuv420p`, `-tune stillimage`, even dimensions, at most 720×720,
  low frame rate (the builder picks one AVPlayer and HLS segmenting are happy
  with; 1–2 fps keeps the file small);
- AAC, 44.1 kHz stereo, 256 kbps;
- `-shortest` so the video stops with the audio;
- `-metadata title= artist= album= comment=spotify:track:<id>` (the same
  convention as YouTube's `comment=<id>`), and `-movflags +faststart`.

It is a job kind, not a BackgroundTask ffmpeg call, per the converter
invariant. Priority 0 (interactive). Like `normalize`, it stays out of
`GET /api/jobs`.

### 6. Clients

Nothing is required, because the row is an ordinary download with
`platform="spotify"`, a title, a channel and a `preview_url`. Things the builder
checks rather than assumes:

- iOS and the web page do not reject or mislabel an unknown `platform` value
  (any `switch` or enum over platforms).
- The iOS share extension (if it filters URLs) lets `open.spotify.com` through.
- The `save_video` skill's URL check, if it has one.

### 7. Ops

**The recorder is a fourth `./serve` pane, role `spotify`, run exactly like
`convert`:**

- `run_spotify` in `./serve`:
  `exec > >(colorize <color> spotify) 2>&1`, then
  `until "$SPOTIFY_RECORDER_BIN" serve --cache … --listen 127.0.0.1:$SPOTIFY_RECORDER_PORT; do sleep 1; done`.
  The until-loop respawns it on a crash, and a clean SIGTERM exit only comes
  from `./serve` replacing the pane. Pick a label color the other panes don't
  use (e.g. 92, bright green, Spotify's).
- Before the loop, the pane runs
  `cargo build --release --manifest-path tools/spotify-recorder/Cargo.toml`,
  which does nothing when the binary is up to date. So a Rust change takes
  effect on the next `./serve`, like a `converter.py` change. *(My call.)*
  If the build fails or `cargo` is missing, the pane prints why and then
  **stays alive idle** (e.g. `exec sleep 2147483647`). Spotify links then fail
  cleanly with connection refused, and the rest of the server boots normally. A
  missing Rust toolchain must never stop PatataTube from serving.
- The `--pane` case statement gains `spotify)`. The launcher stops it with the
  others (`for role in web convert spotify caddy`), starts it after `convert`
  and before `web` (`start_pane spotify`, then `verify_pane spotify 3`), and
  the final "Serving" line names it.
- `stop_strays` also stops a stray `spotify-recorder serve` outside the
  session: two would both bind the port, or fight over one Spotify account.
- `FORWARD_VARS` gains `SPOTIFY_RECORDER_BIN SPOTIFY_RECORDER_PORT
  SPOTIFY_CACHE_DIR`.
- `./serve`'s header comment and CLAUDE.md's description of the session ("one
  pane each for `caddy`, `convert` and `web`") are updated to four panes.

Also:

- The new `spotify` converter job lives in `converter.py`, so it needs a full
  `./serve` restart (`--reload` does not restart the converter).
- Setup on the macmini, once (after the first `./serve` has built the binary):
  ```
  tools/spotify-recorder/target/release/spotify-recorder login --cache data/spotify
  ```
- `log/backend.log` gets the service's own lines under the `spotify` label,
  plus the downloader's `[spotify] record <id> secs=N` and a failure reason
  line. No tokens.

## Testing

Python (pytest, no network, no Rust binary: the `/record` call is stubbed,
e.g. an `httpx.MockTransport` or a monkeypatched client, and the stub writes a
PCM fixture to `out` and returns the JSON):

- `_classify_url`: track URL variants, `intl-xx`, `?si=`, the `spotify:track:`
  URI, a bad id length, and an album/playlist link → 400.
- `upload` dedupe moves an existing completed `spotify` row.
- `download_video` spotify branch: success enqueues a `spotify` job with the
  right payload and ends `done`; a 404, a 401, connection refused, a short
  recording and a silent recording each delete the row; a cover download
  failure still succeeds with `cover_path=None`.
- Converter `spotify` job: builds the expected ffmpeg command (unit test on the
  command builder; one real-ffmpeg test on a 1 s PCM fixture is welcome if fast).

Rust: no test suite. The spike, plus a manual checklist:

- login;
- record a known track;
- an unavailable track;
- bad credentials;
- two `/record` calls at once come out one after the other;
- `./serve` twice in a row leaves exactly one `spotify-recorder serve`;
- with `cargo` off `PATH`, `./serve` still boots and the pane idles.

iOS: no change expected, so no iOS test runs.

## Spike first

Before the plan's main tasks: build `/record` against one real track and
measure:

1. that it records at all with cached device-code credentials;
2. **speed**: wall time against track length;
3. that the PCM duration matches `duration_ms`.

If it records in real time, nothing in the design changes (the queue and the
timeout already allow for it), but the timeout default may need to grow.

## Left to the builder

- Frame rate and cover size for the still-image video, within the limits above.
- The silence-check method and threshold.
- How the recorder's metadata picks the "largest" cover.
- Log wording.

## Calls I made (not discussed)

- **The song is stored as a video with the album cover as its picture**,
  because the whole pipeline (normalize, HLS, SD, grid players) requires a
  video stream.
- **The spotatui librespot fork** over upstream, for its silent-playback fix.
- **AAC 256 kbps** from a 320 kbps Vorbis source.
- **Track links only**; `spotify.link` short links are left out.
- **The recorder is a long-running service in its own `./serve` pane** (your
  requirement). My calls inside it: it is reached over localhost HTTP, one
  async mutex enforces one-at-a-time, one Spotify session is kept for its
  whole life, and the pane builds the binary with `cargo` on start and idles,
  instead of crashing the boot, when that fails.
- **Validation** fails the download on a ±2 s duration mismatch or silence.
