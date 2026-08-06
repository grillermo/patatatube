# Plan — `DEVLOG`: agent-readable runtime instrumentation for the iOS app

**Goal.** Give the coding agent a real-time, structured log of what the iPad app
is doing — taps, playback state machine, stream-proxy requests, cache state
transitions, download lifecycle, errors — so the *random playback failures* can
be diagnosed from evidence instead of guesses.

**Hard constraint.** The app that actually fails ships as a **Release `.ipa`
sideloaded via AltStore onto a real iPad** (`ios/ipa_builder.rb` archives
`-configuration Release`). So:

- `#if DEBUG` is useless here — the failing build is Release.
- Writing to a host filesystem path is useless here — there is no host.

Therefore: a dedicated **`DEVLOG` compilation condition** (orthogonal to
Debug/Release) and **two sinks** — host file in the Simulator, HTTP POST to the
existing FastAPI backend on device.

---

## 1. Design

### 1.1 The flag

New Swift compilation condition `DEVLOG`, injected at build time, *not* checked
into `project.yml` defaults:

```
SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG'
```

**Verified with `#error` probes in both targets. The results changed the design,
so they are recorded here:**

| Build | App target | PatataTubeKit |
|---|---|---|
| Release, no flag | off | off |
| Release + flag on the `xcodebuild` command line | **on** | **on** |
| Debug, project-level `settings.configs.Debug` only | **on** | **off** |
| Debug, after adding `.define(…, .when(configuration: .debug))` | on | **on** |

So there are two mechanisms, not one:

- **Release** gets it from the `xcodebuild` command line
  (`ipa_builder.rb`, `--instrumented`). That reaches every target including
  SwiftPM packages — no `OTHER_SWIFT_FLAGS` fallback was needed.
- **Debug** gets it from `project.yml` (app target) **and** from
  `PatataTubeKit/Package.swift` (`swiftSettings: [.define("DEVLOG",
  .when(configuration: .debug))]`). An Xcode *project-level* build setting does
  **not** reach SwiftPM package targets, and most of the interesting code
  (`CacheManager`, `StreamProxy`) is in the package — so the package
  declaration is required, not redundant.

The test target needs the same `.define`, or the tests' `#if DEVLOG` disagrees
with the `DevLog.enabled` compiled into the library they link against.
Consequence: `swift test` runs instrumented, `swift test -c release` runs
silent. Both halves are meaningful; run both.

Every call site compiles to nothing when the flag is absent — no strings built,
no allocations, no queue hops.

### 1.2 `DevLog` core — `ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`

Public API, always present; body compiled out without `DEVLOG`.

```swift
public enum DevLog {
    public enum Kind: String, Sendable {
        case tap, nav, play, proxy, cache, download, net, state, error, lifecycle
    }

    @inlinable
    public static func event(
        _ kind: Kind,
        _ message: @autoclosure () -> String,
        _ meta: @autoclosure () -> [String: String] = [:],
        file: String = #fileID, line: Int = #line, function: String = #function
    ) {
        #if DEVLOG
        _emit(kind, message(), meta(), file, line, function)
        #endif
    }
}
```

`@autoclosure` matters: with the flag off the interpolation never runs; with it
on it still runs on the caller's thread, so keep meta cheap (no `ffprobe`, no
directory walks — precomputed values only).

Record shape (one JSON object per line):

```json
{"ts":"2026-07-30T14:55:40.123Z","seq":184,"session":"7F2A…","kind":"play",
 "msg":"item status -> failed","src":"VideoPlayerView.swift:187","fn":"playWhenReady(item:on:)",
 "meta":{"video_id":"812","source":"proxy_mp4","err":"-11829","cache":"downloading(0.42)"}}
```

- `session` — UUID minted at launch. Every record carries it. Lets the agent
  isolate one app run.
- `seq` — monotonic counter. Survives out-of-order flushing over HTTP.
- `meta.video_id` / `meta.attempt` on everything playback-related — the whole
  point is reconstructing *one* playback attempt end to end.

### 1.3 Sinks — must never be the bug

This app has already shipped a main-thread hang from synchronous
`NSFileHandle.write` (see the comment at `VideoStore.swift:100`, Sentry
PATATATUBE-2). Instrumentation that stalls I/O while diagnosing a stalling
video is worthless.

- Serial background `DispatchQueue`, `qos: .utility`.
- Fixed-capacity ring buffer (e.g. 4096 records). **Drop oldest on overflow and
  emit a `dropped=N` marker** rather than applying backpressure.
- `os.Logger` mirror for every record (subsystem `com.patatatube.app`, category
  `devlog`) so Console.app / `log stream` works even if both sinks are down.

**Sink A — file (Simulator).** Path from `PATATATUBE_DEV_LOG` env var; the
Simulator writes straight to the host filesystem. Append JSONL, `O_APPEND`,
flush on a timer + on `willResignActive`.

**Sink B — HTTP (device, the important one).** Batch up to N records / 2s,
`POST /api/devlog` with the existing `Authorization: Bearer <UPLOAD_TOKEN>`.
Fire-and-forget; on failure keep records in the ring and retry next tick; never
retry more than once per batch (a retry storm during a network-caused playback
failure would poison the evidence). Uses a **separate ephemeral `URLSession`**
from `CacheManager`'s download session so log traffic can't perturb the
download concurrency gate being measured.

Backend server URL + token come from the existing `CredentialStore`.

### 1.4 Simulator wiring

`ios/PatataTube/project.yml`, `schemes.PatataTube.run`:

```yaml
    run:
      config: Debug
      environmentVariables:
        PATATATUBE_DEV_LOG: /Users/grillermo/c/patatatube/log/ios.jsonl
```

plus a `Debug` config base setting adding `DEVLOG` to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, so a plain Xcode Run is always
instrumented. `log/` is already gitignored.

---

## 2. What gets instrumented (targeted at random playback failure)

Ordered by suspicion. Each bullet is a call site to add.

### 2.1 Playback state machine — `ios/PatataTube/Sources/VideoPlayerView.swift`

- `playerItem(for:)` (~L210) — **which of the five source branches was taken**:
  `local_mp4` (L215) / `offline_hls` (L218) / `proxy_hls` (L229) /
  `proxy_mp4` (L225, L234) / `direct` (L238), or `nil` (L222). Log alongside:
  `CacheManager.state(for:)`, whether the local file exists, its byte size, and
  the resolved URL. *A wrong branch under a partially-cached file is the single
  most likely cause of "random" failure.*
- `playWhenReady(item:on:)` (~L175) — observe and log every
  `AVPlayerItem.status` transition, and on `.failed` dump `item.error`,
  `item.errorLog()?.events` (each `errorStatusCode` / `errorComment` / `uri`)
  and the last `item.accessLog()` event (`indicatedBitrate`, `numberOfStalls`,
  `observedBitrate`, `numberOfServerAddressChanges`).
- New observers: `.AVPlayerItemPlaybackStalled`,
  `.AVPlayerItemFailedToPlayToEndTime`, `.AVPlayerItemNewErrorLogEntry`,
  `AVPlayer.timeControlStatus`, `isPlaybackLikelyToKeepUp`,
  `isPlaybackBufferEmpty`, `loadedTimeRanges` (log the buffered-ahead seconds,
  throttled to ~1 Hz — do **not** log every KVO tick).
- `applyAudioSelection` (L407) — chosen language vs available; a missing track
  in a converted HLS package is a plausible silent failure.
- `AVAudioSession` interruption / route change notifications.

### 2.2 Stream proxy — `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift`

This is a local HTTP server standing between AVPlayer and the backend; it is
the prime suspect for intermittent, timing-dependent failure.

- `handleMP4` (L406) / `handleHLS` (L194) — request path, `Range` header,
  parsed range vs total, response status, bytes served, duration.
- `servePlaylist` (L209), `serveHLSAsset` (L338) — cache hit vs upstream fetch.
- `prepareMP4WithRecovery` (L565), `writeMP4WithRecovery` (L587),
  `storeHLSAssetWithRecovery` (L304) — **every entry into a recovery path is a
  log line.** Recovery firing mid-playback is exactly the shape of a random
  failure.
- `passthroughMP4` (L621), `partialResponse` (L634) — which strategy served it.
- `parseRange` (L650) / `parseContentRange` (L673) / `boundedWindow` (L698)
  failures, and any non-2xx upstream (`isSuccessful`, L187).
- `start()` (L44) / `stop()` (L71) — listening port, and any restart. A proxy
  that stopped while a player still held its URL would look exactly like a
  random failure.

### 2.3 Cache states — `CacheManager.swift` (+ `CacheManager+HLS`, `StreamCacheLRU`, `RangeStore`)

- `state(for:)` (L426) — log the `CacheState` (`notCached` /
  `downloading(fraction)` / `cached`) whenever playback or the UI asks. This is
  the "cache in different states" the bug report needs.
- `download(id:versionId:from:)` (L450) — start, with existing partial byte
  count and whether it resumed.
- `SegmentedAttempt` retries (`maxSegmentRetries`, L116) — each segment retry,
  its index, error, and `durablePrefixByteCount`.
- `urlSession(_:downloadTask:didFinishDownloadingTo:)` (L698),
  `didWriteData` (L727, throttled), `task:didCompleteWithError:` (L765) —
  completion / failure / HTTP status.
- `cancel` (L575), `removeCached` (L622), `removeAllCached` (L637),
  `clearAllVideos` (L656) — **destructive cache mutations, always logged.**
- `CacheManagerCancellationFence` (L43–110) — `beginCancellation` /
  `endCancellation` / rejected mutation (`CancellationError`) /
  `performTerminalClaim` returning false. A cancellation racing a playing item
  is a textbook intermittent failure.
- `resumeInterrupted` (L477) — which ids resumed at launch.
- `StreamCacheLRU` — **every eviction, with the key and the reason.** Evicting
  the bytes of the item currently playing is the leading hypothesis for a
  random mid-playback stall.
- `RangeStore` / `ByteRangeSet` — when a requested range is only partially
  satisfiable, log the gap.

### 2.4 Downloads / UI

- `DownloadConcurrencyGate` — acquire / release / wait, with the queue depth.
- `SegmentedDownload` — attempt begin/end and per-segment outcomes.
- `VideoStore` (`ios/PatataTubeKit/.../VideoStore.swift`) — optimistic mutation
  applied vs rolled back.
- `APIClient` — request → status → duration for every call (no tokens, no
  response bodies).
- Taps: a `View.logTap(_:)` modifier (`simultaneousGesture(TapGesture())`,
  compiled to `self` without `DEVLOG`) applied to `DownloadButton`,
  `VideoCell`, `MovieCell`, `EpisodesView` rows, `VideoGridView` items,
  `SettingsView` toggles, and the player transport controls.
- `PatataTubeApp` — launch, `scenePhase` transitions, memory warnings (reuse
  `MemoryProbe`'s existing footprint numbers), `NSSetUncaughtExceptionHandler`.

### 2.5 Retire the ad-hoc probes

`SpikeDownloadProbe.swift` is 10 bare `print("SPIKE …")` calls. Convert them to
`DevLog.event(.download, …)` so there is exactly one logging path.

---

## 3. Backend — `POST /api/devlog`

New endpoint in `main.py`:

- Token-gated via the existing `_check_token` (Bearer `UPLOAD_TOKEN`).
- Body: `{"session": "...", "records": [ … ]}`, capped (e.g. 512 records /
  1 MB per request) — reject oversize with 413 rather than buffering.
- Appends each record as one JSON line to `log/ios.jsonl` (path from
  `IOS_LOG_FILE`, default `log/ios.jsonl`; `log/` is gitignored).
- **Size cap with rotation** — at 32 MB, rename to `log/ios.jsonl.1` and start
  fresh. An instrumented app left running for a day must not fill the disk.
- Writes off the event loop (`run_in_threadpool` or an `asyncio.Queue` +
  single writer task) — this endpoint must never slow the video endpoints it is
  measuring.
- Returns `204`.
- Tests in `tests/test_api.py` following the existing `client`-fixture pattern
  (reload `db` then `main` after setting env): auth required, append works,
  oversize rejected, rotation triggers.

Optionally mirror to stdout with an `ios` label so `./serve`'s existing
tee picks it up into `log/backend.log` — giving one interleaved
backend + iOS timeline. Decide during implementation; the separate file is the
must-have, the merged view is the nice-to-have.

---

## 4. `./deploy` + `/deploy-ios` — instrumented builds

An instrumented `.ipa` must be *easy to ship* and *impossible to ship by
accident*.

### 4.1 `ios/ipa_builder.rb`

- `build(instrumented: false)`.
- When true, append to the `xcodebuild` invocation:
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG'`
  (or the fallback determined in 1.1).
- Print a loud banner: `⚠️  INSTRUMENTED BUILD (DEVLOG active)`.

### 4.2 `./deploy`

- New flag `--instrumented` (also `PATATATUBE_DEVLOG=1`).
- Version suffix so an instrumented build is identifiable on the iPad and in
  the manifest: `localizedDescription` in `apps.json` prefixed
  `[DEVLOG] `, and an Info.plist key `PTDevLogBuild = YES` surfaced in
  `SettingsView`.
- **Interactive confirmation before publishing an instrumented build to the
  public AltStore source** — this cuts a public GitHub Release. Skipped only
  with `--yes`.
- `--dry-run` must report the instrumented state.
- Follow-up guard: after a `--instrumented` release, print the exact command to
  ship a clean build back over it.

### 4.3 `.claude/skills/deploy-ios/`

- `deploy-ios.sh` — pass through a `--instrumented` flag to `./deploy`.
- `SKILL.md` — new "Instrumented builds" section: what `DEVLOG` is, when to use
  it (reproducing playback bugs on the real iPad), that it is a **public
  release** like any other, where the logs land (`log/ios.jsonl` on the
  server), and an explicit instruction to ship a clean build afterwards.
  Add a Gotchas row: *never leave the AltStore source on an instrumented build.*

---

## 5. CLAUDE.md

Add under **Commands → iOS** and a short **Architecture** subsection:

> **Debugging the iOS app: read `log/ios.jsonl`.**
> Instrumented builds (compiled with the `DEVLOG` condition) emit structured
> JSONL — one JSON object per line: `ts`, `seq`, `session`, `kind`
> (`tap`/`nav`/`play`/`proxy`/`cache`/`download`/`net`/`state`/`error`/`lifecycle`),
> `msg`, `src`, `fn`, `meta`. Simulator runs write straight to the host path in
> `PATATATUBE_DEV_LOG` (scheme env var); device builds `POST /api/devlog` to the
> backend, which appends to the same file. `DevLog` lives in
> `ios/PatataTubeKit/Sources/PatataTubeKit/DevLog.swift`; every call site
> compiles to nothing without `DEVLOG`, so **a normal release logs nothing** —
> add call sites via `DevLog.event`, never `print`.
> Build one with `.claude/skills/deploy-ios/deploy-ios.sh --instrumented`.

Useful reads for the agent:

```bash
tail -n 300 log/ios.jsonl
grep '"kind":"error"' log/ios.jsonl | tail -30
jq -c 'select(.meta.video_id=="812")' log/ios.jsonl        # one video's whole story
jq -c 'select(.kind=="play" or .kind=="proxy" or .kind=="cache")' log/ios.jsonl
```

---

## 6. Order of work

1. **Prove the flag reaches PatataTubeKit** (1.1). Everything else depends on it.
2. `DevLog.swift` + ring buffer + file sink + `os.Logger` mirror; unit tests in
   `PatataTubeKit` asserting no-op without `DEVLOG` and correct JSON with it.
3. `project.yml` scheme env + Debug config condition. Smoke-test in the
   Simulator: tap something, see a line in `log/ios.jsonl`.
4. Backend `POST /api/devlog` + tests + rotation.
5. HTTP sink in `DevLog`; smoke-test on a device build.
6. Instrument in suspicion order: **2.1 playback → 2.2 proxy → 2.3 cache** →
   2.4 downloads/UI → 2.5 retire `SPIKE` prints.
7. `ipa_builder.rb` / `./deploy` / `deploy-ios.sh` / `SKILL.md`.
8. CLAUDE.md.
9. Ship one instrumented build, reproduce the failure, read the log.
10. **Ship a clean build.**

## 7. Confirming the ranked hypotheses

The prior static analysis (`playbackbug-mobile-format.html`) ranks seven
candidate causes for *"buffers, then fails — including on already-downloaded
videos"*. Each one below has a record that decides it. Nothing here is inferred
from absence: every hypothesis has a positive signal.

### H1 — proxy down, so downloaded videos fall through to the network *(primary)*

`localURL(kind:…)` returns `nil` whenever the proxy is not listening, which
kills the **offline** route too, not just the network ones.

| Record | Meaning |
|---|---|
| `proxy bind failed` / `proxy listen failed` | the proxy never came up; every proxied URL is `nil` for the whole run |
| `proxy start requested` / `proxy started` `port=…` | `port=nil` here is the same fault; a *missing* pair around a playback means the startup race won |
| `proxied URL unavailable — proxy not listening` `kind=offline` | **the decisive one** — a downloaded HLS package just lost its local path |
| `source -> …` `meta.proxy_port` | `nil` alongside `source=direct_hls`/`direct_mp4` proves H1 caused that stream |

Confirmed by: `source=direct_*` **and** `proxy_port=nil` **and**
`any_version_cached=true` on the same video.

### H2 — version-key drift makes a downloaded file invisible *(primary)*

`state(for:versionId:)` probes paths that embed `chosenVersionId`; if the server
changes the chosen version the file is still on disk under the old key.

`source -> …` carries `cache`, `version_id`, `local_path`, `local_exists`,
`local_bytes` and **`any_version_cached`**. The signature is
`cache=notCached` **and** `any_version_cached=true` — some version is cached,
this one isn't, so playback went to the network. `cached but no local source`
covers the related case where the cache claims `.cached` and neither offline
route resolves.

Note this cleanly separates H1 from H2, which the static analysis could not do:
H1 shows `proxy_port=nil`, H2 shows a live port with a key mismatch.

### H3 — `resumeInterrupted` bypasses the concurrency gate *(why the network died)*

- `resumeInterrupted (ungated by concurrencyGate)` — `resumed` is how many
  transfers started at once with no permit, and it re-fires on every foreground.
- `gate acquired` / `gate queued` / `gate released` — `active`/`limit`/`waiting`
  for downloads that *did* go through the gate.
- Backend, in `log/backend.log`: `[stream] +1 … active=N/16`, `-1`, and
  `[stream] saturated: 16/16 permits held, queuing …`.

Confirmed by: backend `active` reaching the limit while the app's `gate active`
stays at or below its own limit — the gap is exactly the ungated resumes. The
`saturated` line is the permit exhaustion the analysis predicted, stated
directly rather than counted by hand out of an access log.

### H4 — assembly needs 2× the movie free, so the queue never drains

- `assembly starting` — `total_bytes` and `free_bytes` at the moment it matters.
  `free_bytes < total_bytes` predicts the failure before it happens.
- `assembly FAILED — manifest discarded, restarts from zero` — with the error
  and free space.
- `manifest removed` — every discard, which is what makes the next foreground
  restart the transfer from zero.

Confirmed by: `assembly FAILED` followed by `resumeInterrupted` re-including the
same id. That is the feedback loop, observed rather than deduced.

### H5 — disk exhaustion turns the proxy cache into an evict/refetch loop

`MP4 prepare failed, evicting and retrying`, `MP4 write failed, evicting and
retrying`, `HLS store failed, evicting and retrying`, then `… passing through` /
`staying pass-through`, plus `evicted for storage failure`. Repetition at
increasing frequency with low `free_bytes` is the loop.

### H6 — the LRU sweep is O(every file) and runs per request

`LRU sweep slow` with `ms` and `entries`, emitted whenever a sweep exceeds
100 ms. Frequency and duration together give the stampede; sweeps under the
threshold stay silent so this cannot itself flood the log.

### H7 — eviction can delete the entry currently playing

`LRU over budget` then `LRU evicted` with `entry`, `bytes`, `accessed`,
`remaining`. Correlate `entry` against the `source -> …` record for the video
playing at that `ts`. An eviction naming the active entry, followed by
`MP4 cache read empty, passing through` or a `buffer empty` / `playback
stalled`, confirms it.

### Ruled-out items stay checkable

The analysis ruled out corrupt local files and head-of-line blocking on the
in-process server by reading the code. `assembly FAILED` (length mismatch) and
the per-request `proxy` timing records (`ms` per route) keep both falsifiable at
runtime rather than resting on the reading.

## 8. Risks

- **Observer effect.** Logging adds work on the playback path. Mitigations:
  autoclosure, ring buffer, background queue, throttled KVO, separate
  `URLSession`. If the failure stops reproducing under `DEVLOG`, that is itself
  a finding (points at a timing race) — note it, don't dismiss it.
- **A public release carries the instrumented build.** Mitigated by the
  confirmation prompt, the `[DEVLOG]` manifest marker, and the follow-up guard.
- **Log volume.** Bounded by the ring buffer, batch caps, backend size cap, and
  throttled high-frequency sources.
- **Leakage.** Records must carry no bearer tokens and no response bodies —
  ids, statuses, byte counts, error codes only. Add an explicit review pass over
  every `meta` dictionary before shipping.
