# HLS iOS caching — unresolved unknowns, device spike

**Status:** shipped without this. PatataTube iOS 1.2.0 (build 89) went out on
2026-07-26 with the full HLS read-through caching rewrite
(`docs/superpowers/plans/2026-07-26-hls-stream-caching.md`), but the plan's
own Task 0 — a physical-device spike answering four `AVAssetDownloadURLSession`
behaviors — never ran. No iPad was available in the environment that
implemented it. The four answers currently baked into the shipped code come
from Apple developer forum research, not a measured device run. That's weaker
evidence, and two of the four have documented real-world reliability problems.

This doc is the belated Task 0: what to run on the iPad, and what to tell me
depending on what you see, so I can react correctly instead of guessing.

## Why this matters

The whole design's premise is: hand `AVPlayerItem` the *download task's own*
`AVURLAsset` during playback, so watching a video is also downloading it, and
a later explicit download only fetches the segments that watch didn't already
get. Four things have to be true for that to hold:

| # | Question | What's assumed right now | Confidence |
|---|---|---|---|
| 1 | Cancel an `AVAggregateAssetDownloadTask`, recreate one for the same asset later — does it resume from where it left off, or restart from 0%? | `HLSDownloadEngine.makeAsset(for:)` resumes by pointing the new task at the **local** persisted `.movpkg` URL (not the remote master) when an incomplete entry exists — the safer of two options, but not proven | Low — Apple forum threads report this is undocumented/inconsistent for `AVAggregateAssetDownloadTask` specifically |
| 2 | Is `task.urlAsset` playable *while the download is still running*, serving already-downloaded segments from disk? | Yes, this is the core of `playbackAsset(for:isOnWiFi:hasNetwork:)`'s `.fillAhead` case | High — this is Apple's own documented pattern |
| 3 | Does a partial (incomplete) `.movpkg` play offline for its downloaded region? | Yes — `PlaybackAssetProvider.decide` returns `.localPackage` for an incomplete entry when `hasNetwork == false` | Medium — works in forum reports, but with documented issues: 10–60s load delays, occasional "asset loss," inconsistent across sessions |
| 4 | Does `AVAggregateAssetDownloadTask` preserve multiple audio/subtitle `AVMediaSelection`s, available offline via `AVAssetCache`? | Yes, `HLSDownloadEngine.start` passes `asset.allMediaSelections` to the aggregate task | High — this is exactly what the API is designed for |

Full research write-up: see `docs/superpowers/specs/2026-07-25-hls-stream-caching-design.md`,
section `## Spike findings (2026-07-26)`.

**Net risk:** #2 and #4 are solid. #1 and #3 are the ones that can actually
bite a user — a resumed download silently re-fetching everything (wastes
data, but not a crash), or a partial offline video that hangs/errors instead
of playing (a real bug report).

## What ships today if these are wrong

- If #1 is false (restarts from 0): no correctness bug, just wasted cellular/Wi-Fi
  data on every resumed download. Silent, no crash, no error shown to the user.
- If #3 is false (partial offline is unreliable): a user opens a partially-downloaded
  video in Airplane Mode and gets a long spinner, a stuck player, or an error —
  looks like the app is broken.

## Manual steps to run

You need a physical iPad on PatataTube 1.2.0 (or a fresh dev build), Xcode
attached for console output, and the ability to toggle Airplane Mode.

### Setup

```bash
cd /Users/grillermo/c/patatatube
git status   # confirm clean, note current branch (should be main)
git checkout -b spike/hls-download-probe
```

### Step 1 — add the probe

Create `ios/PatataTube/Sources/SpikeDownloadProbe.swift`:

```swift
import AVFoundation
import Foundation

/// Throwaway spike. Prints answers to the four unknowns above. Delete before
/// merging anything — this never ships.
final class SpikeDownloadProbe: NSObject, AVAssetDownloadDelegate {
    private var session: AVAssetDownloadURLSession!
    private var task: AVAggregateAssetDownloadTask?
    private var localURL: URL?
    private var fractionAtCancel: Double = 0

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "spike.hls.probe")
        session = AVAssetDownloadURLSession(
            configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }

    /// `master` is an authed https master.m3u8 URL; `token` the bearer token.
    func start(master: URL, token: String) async {
        let asset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        let selections = asset.allMediaSelections
        print("SPIKE q4: allMediaSelections count = \(selections.count)")
        task = session.aggregateAssetDownloadTask(
            with: asset, mediaSelections: selections, assetTitle: "spike",
            assetArtworkData: nil, options: nil)
        task?.resume()

        // Cancel at roughly 20%, then restart and observe whether the first
        // progress report resumes near 20% (resume) or near 0% (restart).
        try? await Task.sleep(for: .seconds(20))
        print("SPIKE q1a: cancelling at fraction \(fractionAtCancel)")
        task?.cancel()
        try? await Task.sleep(for: .seconds(3))
        let restartAsset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        task = session.aggregateAssetDownloadTask(
            with: restartAsset, mediaSelections: restartAsset.allMediaSelections,
            assetTitle: "spike", assetArtworkData: nil, options: nil)
        task?.resume()
    }

    /// q1b: restart from the *local* partial URL instead of the remote master —
    /// this is what the shipped HLSDownloadEngine actually does. Run this
    /// variant if q1a shows a restart-from-0, to confirm the local-URL path
    /// (already shipped) does or doesn't fare better.
    func restartFromLocal() {
        guard let localURL else { print("SPIKE q1b: no local URL captured"); return }
        let asset = AVURLAsset(url: localURL)
        task = session.aggregateAssetDownloadTask(
            with: asset, mediaSelections: asset.allMediaSelections,
            assetTitle: "spike", assetArtworkData: nil, options: nil)
        task?.resume()
    }

    /// q2: play the running task's asset and print whether playback starts.
    func playRunningTaskAsset() {
        guard let asset = task?.urlAsset else { print("SPIKE q2: no task"); return }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q2: status=\(item.status.rawValue) time=\(player.currentTime().seconds)")
        }
    }

    /// q3: after cancelling, play the partial from its local URL (run in Airplane Mode).
    func playPartialOffline() {
        guard let localURL else { print("SPIKE q3: no local URL"); return }
        let item = AVPlayerItem(asset: AVURLAsset(url: localURL))
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q3: status=\(item.status.rawValue) error=\(String(describing: item.error)) time=\(player.currentTime().seconds)")
            let groups = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            print("SPIKE q4 offline: legible options = \(groups?.options.count ?? -1)")
        }
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        localURL = location
        print("SPIKE willDownloadTo: \(location.path)")
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection
    ) {
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let fraction = expected > 0 ? loaded / expected : 0
        fractionAtCancel = fraction
        print("SPIKE progress: \(fraction) bytesReceived=\(aggregateAssetDownloadTask.countOfBytesReceived)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("SPIKE didComplete error=\(String(describing: error))")
    }
}

enum SpikeProbeHolder {
    @MainActor static var shared: SpikeDownloadProbe?
}
```

### Step 2 — hang a trigger in Settings

In `ios/PatataTube/Sources/SettingsView.swift`, inside the last `Section { … }`
(the one holding "Cache all videos"), add:

```swift
                    Button("SPIKE: probe HLS download") {
                        guard let base = model.credentials.baseURL,
                              let token = model.credentials.token,
                              let video = model.store.videos.first(where: { $0.hlsPath != nil }),
                              let path = video.hlsPath else { return }
                        let master = base.appendingPathComponent(
                            path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                        let probe = SpikeDownloadProbe()
                        SpikeProbeHolder.shared = probe
                        Task { await probe.start(master: master, token: token) }
                    }
                    Button("SPIKE: play running task asset") { SpikeProbeHolder.shared?.playRunningTaskAsset() }
                    Button("SPIKE: restart from local URL") { SpikeProbeHolder.shared?.restartFromLocal() }
                    Button("SPIKE: play partial offline") { SpikeProbeHolder.shared?.playPartialOffline() }
```

### Step 3 — build, install, run

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Install on the iPad the same way `./deploy`/AltStore normally does, or via
Xcode's Run button with the device selected. Open Xcode → Window → Devices
and Simulators → open the device console, filter on `SPIKE`.

### Step 4 — exercise it, in order

1. Open the app, go to Settings, make sure at least one video has an HLS
   package (`hls_path` present — any previously-played video qualifies).
2. Tap **"SPIKE: probe HLS download"**. Watch the console. It downloads for
   20s, cancels, waits 3s, and starts a fresh task from the *remote* master.
   Watch what the first `SPIKE progress:` line reads after the restart.
3. While the second (post-restart) download is running, tap
   **"SPIKE: play running task asset"**. Watch for `SPIKE q2:` — does
   `status=1` (readyToPlay) appear with a non-zero `time`?
4. Let the download run a bit longer, then tap **"SPIKE: restart from local
   URL"** to compare — cancel isn't needed again, this just demonstrates the
   local-URL resume path the shipped code actually uses. Compare its first
   progress reading against step 2's remote-restart reading.
5. Turn on **Airplane Mode**.
6. Tap **"SPIKE: play partial offline"**. Watch for `SPIKE q3:` — does
   `status=1` appear with `error=nil`? Does `SPIKE q4 offline:` show
   `legible options` > 0 (if the source video has subtitles)?

### Step 5 — record the answers

Fill this in and send it back to me:

```
1. Remote-restart resume: <resumes from ~N% | restarts from 0%>
1b. Local-URL restart resume: <resumes from ~N% | restarts from 0%>
2. task.urlAsset playback while downloading: <works, time=X | fails: ...>
3. Partial .movpkg offline playback: <works, time=X | fails: status=..., error=...>
4. allMediaSelections count at start: <N>; legible options offline: <N>
```

### Step 6 — clean up regardless of outcome

```bash
cd /Users/grillermo/c/patatatube
git checkout main
git branch -D spike/hls-download-probe
```

Nothing from this branch ships. Delete the SPIKE buttons/file even if you
were mid-investigation — reopen the branch from git history if you need the
probe again later.

## What to tell me, and what I'll do about it

Paste me the Step 5 answers verbatim. Here's what each outcome means for the
shipped code:

**Q1/Q1b — resume**
- *Both resume correctly (remote and local):* no action needed. Update the
  spec's confidence rating from research-based to device-confirmed.
- *Remote restarts from 0, but local-URL resume works:* good — that's exactly
  what's shipped (`HLSDownloadEngine.makeAsset(for:)` already prefers the
  local URL). No code change, just confirms the existing choice was right.
  I'll update the spec to mark this device-confirmed instead of researched.
- *Both restart from 0, nothing resumes:* real but non-corrupting bug — every
  cancelled-then-resumed download silently re-fetches everything, burning
  data. I'll add a fallback: track byte ranges already seen (mirroring what
  the old deleted `RangeFetcher` did for MP4) isn't available for HLS segments
  through this API, so the fix is more likely tuning UX — e.g. warn before
  resuming a large cancelled download, or stop auto-cancelling fill-ahead on
  every `notePlaybackEnded` and instead let it run to completion in the
  background more aggressively. I'll propose a specific approach once I see
  which failure mode this actually is.

**Q2 — play while downloading**
- *Works:* expected, no action.
- *Fails:* this breaks the core premise of the whole rewrite — the read-through
  cache doesn't work. This is a stop-ship-caliber finding for anything not
  already released. Tell me immediately; I'll need to re-open
  `docs/superpowers/specs/2026-07-25-hls-stream-caching-design.md`'s "Decisions"
  table and likely revisit the no-proxy constraint that ruled out
  `AVAssetResourceLoaderDelegate` in the first place — that constraint may
  need to be relaxed, which is a materially different design, not a patch.

**Q3 — partial offline playback**
- *Works cleanly:* update the spec's confidence rating, no code change.
- *Works but slow/flaky (the forum-reported failure mode):* not stop-ship, but
  worth a UX fix — I'll add a loading-state affordance in `VideoPlayerView`
  for partial offline playback specifically (distinct from the general
  12-second `playWhenReady` timeout, since forum reports mention 10-60s
  delays that would blow past that), and consider a "retry" path if
  `AVPlayerItem.status == .failed` for a partial package.
- *Fails outright (status=.failed or item.error set):* also not stop-ship on
  its own, since `PlaybackAssetProvider` only serves `.localPackage` for a
  partial when offline and there's nothing else to fall back to — but I'll add
  an explicit "can't play this offline yet" message instead of a silently
  broken player, and consider whether `notePlaybackEnded` should require a
  minimum download fraction before treating a partial as playable at all.

**Q4 — media selections**
- *Count > 1 and offline options > 0:* expected, no action.
- *Count is 1 or offline options is 0:* means multi-audio/subtitle library
  videos lose their language picker once downloaded. I'll need to check
  whether `HLSDownloadEngine.start`'s `asset.allMediaSelections` call is
  actually being evaluated before the asset's playlist is loaded (a common
  AVFoundation gotcha — media selections sometimes need an explicit
  `load(.availableMediaCharacteristicsWithMediaSelectionOptions)` first), and
  patch `start(_:)` accordingly.

If you hit something not covered above, paste the raw console output and I'll
work from that instead of guessing.
