# Streaming MP4 Proxy and Shared Per-Video Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Long videos play at once through the iOS stream proxy, and playback and downloads share one per-video byte store, so watched bytes are kept and a download starts from whatever was already watched.

**Architecture:** A new `MediaStore` actor owns one entry per cache key under `Documents/videos/.store/<key>/` (sparse `data.bin` + `entry.json`) plus in-memory *claims*: ranges a fetcher is downloading right now. Claims never overlap. `RangeFetcher` streams one upstream `Range` request into a claim, committing every 256 KB. `StreamProxy` answers AVPlayer's **full** requested range as a streamed 206 (FlyingFox `HTTPBodySequence` over a custom `AsyncBufferedSequence`). It reads committed bytes from disk, waits for a nearby fetcher, or runs its own playback fetcher, which parks 32 MB ahead of the reader. `CacheManager` keeps its public API, and a download becomes a pinned entry filled by `DownloadJobRunner`. Whatever closes the last hole renames `data.bin` to `videos/<id>.mp4`.

**Tech Stack:** Swift 6 (strict concurrency), PatataTubeKit SwiftPM package, FlyingFox 0.27.1 (+ its `FlyingSocks` product), URLSession per-task delegates, Swift Testing and XCTest, AVFoundation (macOS smoke test).

**Spec:** `docs/superpowers/specs/2026-11-21-streaming-mp4-proxy-design.md` (approved 2026-11-21). Read it before starting.

---

## Conventions for this plan

**Where:** everything happens in the worktree `/Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy` on branch `streaming-proxy`. That branch already contains the `remove-hls` work (2ff3cf6), which is the base the spec asks for. Never `cd` to the main checkout.

**Toolchain:** bare `swift` picks the wrong toolchain on this machine. Prefix every `swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Ignore SourceKit "no such module" noise in editors.

The kit commands below are run from `ios/PatataTubeKit`:

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTubeKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests
```

**Test runs need the owner's go-ahead.** `CLAUDE.md` says the iOS test suites (`swift test`, `xcodebuild … test`) run only when the owner explicitly asks. Task 1 asks once whether filtered kit runs (`swift test --filter <Suite>`) are allowed while executing this plan.
- **Yes:** follow every "Run" step as written.
- **No:** replace each "Run the test" step with `swift build --build-tests` (it compiles the tests without running them). Task 14 then batches every run for the owner.

**Commits:** PatataTube is a production service (served from `~/c/server/Caddyfile`), so a task commits only after it is validated: its filtered tests pass, or, if test runs were declined, `swift build --build-tests` succeeds. In the second case, say so in the commit body ("tests compiled, not run"). Stage only the files the task names, and end every commit message with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

**Swift 6 strictness:** the package is `swift-tools-version: 6.0`, so data-race errors fail the build. The code below was written for that mode. If the compiler rejects a signature, fix it without changing behavior. Typical cases: a `@Sendable` on a delegate completion, or `FileHandle` not being `Sendable` on an older SDK (wrap it in an `@unchecked Sendable` box). Don't weaken a lock or an actor boundary to make it compile.

**Do not deploy.** `CLAUDE.local.md` skips the deploy on non-release branches, and the spec gates 2.9.0 on an on-device check (Task 14).

---

## File map

Create (kit sources, `ios/PatataTubeKit/Sources/PatataTubeKit/`):

| File | Responsibility |
|---|---|
| `MediaKey.swift` | Cache key ↔ video/version ids ↔ finished filename. |
| `MediaEntryManifest.swift` | `MediaIdentity`, `DownloadJobParameters`, `PinState`, `MediaEntryManifest`, `MediaStoreError`. |
| `DownloadPlanner.swift` | Pure: where download fetchers start next (holes first, then split the largest remainder). |
| `MediaStore.swift` | The actor: entries, claims, commits, promotion, readers, pins, LRU, change notification. |
| `LegacyCacheMigration.swift` | First-launch cleanup of 2.8 caches; paused downloads become paused pinned entries. |
| `DataTaskStream.swift` | One URLSession data task as an async chunk sequence with suspend/resume flow control. |
| `ReadAheadLimiter.swift` | Parks a playback fetcher once it is `lead` bytes ahead of its reader. |
| `UpstreamRequests.swift` | Builds upstream `Range` requests from the *current* base URL and token. |
| `IdentityProbe.swift` | `bytes=0-0` probe → `MediaIdentity`. |
| `RangeFetcher.swift` | Streams one claim from upstream into the store, retrying from its last commit. |
| `DownloadJobRunner.swift` | One download: probe, then keep `streamCount` fetchers on the holes until promotion. |
| `ProxyBody.swift` | `ProxyReadSession` + `ProxyBody` (the streamed response body). |

Rewrite: `CacheManager.swift`, `StreamProxy.swift`.
Modify: `ByteRangeSet.swift`, `CacheStatistics.swift`, `PausedDownloadStore.swift` (doc only), `Package.swift`, `ios/PatataTube/Sources/AppModel.swift`, `CLAUDE.md`.
Delete (Task 11): `RangeStore.swift`, `StreamCache.swift`, `StreamCacheLRU.swift`, `SegmentByteSink.swift`, `SegmentedDownload.swift`. `DownloadByteRange` moves into `ByteRangeSet.swift` first.

Tests (`ios/PatataTubeKit/Tests/PatataTubeKitTests/`):
- Create: `MediaStoreTestSupport.swift`, `DownloadPlannerTests.swift`, `MediaStoreTests.swift`, `MediaStoreLifecycleTests.swift`, `LegacyCacheMigrationTests.swift`, `DataTaskStreamTests.swift`, `RangeFetcherTests.swift`, `DownloadJobRunnerTests.swift`, `AVPlayerSmokeTests.swift`, `Fixtures/tiny.mp4`.
- Rewrite: `CacheManagerTests.swift`, `CacheManagerPauseTests.swift`, `StreamProxyTests.swift`.
- Modify: `ChunkedRangeProtocol.swift`, `CacheStatisticsCollectorTests.swift`.
- Delete: `CacheManagerSegmentSinkTests.swift`, `StreamCacheSeedTests.swift` (Task 9), and `RangeStoreTests.swift`, `SegmentedDownloadTests.swift`, `SegmentByteSinkTests.swift`, `StreamCacheTests.swift`, `StreamCacheLRUTests.swift` (Task 11).

---

### Task 1: Prepare the package and ask about test runs

**Files:**
- Modify: `ios/PatataTubeKit/Package.swift`

- [ ] **Step 1: Ask the owner once**

Ask in chat, as a single question:

> CLAUDE.md says the iOS tests only run when you ask. This plan is TDD across 14 tasks. May I run filtered kit tests (`swift test --filter <Suite>`, a few seconds each) while implementing? If not, I'll compile the tests at each task (`swift build --build-tests`) and ask you to run the whole suite at the end.

Record the answer and follow the matching branch of the *Conventions* section for the rest of the plan.

- [ ] **Step 2: Add the FlyingSocks product**

`AsyncBufferedSequence` (what a streamed FlyingFox body is built from) lives in FlyingFox's `FlyingSocks` product, which FlyingFox does not re-export. In `Package.swift`, change the library target's dependencies to:

```swift
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests`
Expected: `Build complete!` (no source uses FlyingSocks yet).

- [ ] **Step 4: Commit**

```bash
git add ios/PatataTubeKit/Package.swift
git commit -m "kit: depend on FlyingSocks for streamed proxy bodies

FlyingFox's HTTPBodySequence streams any AsyncBufferedSequence, which
lives in the FlyingSocks product and is not re-exported.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Keys, manifest types and the download planner

**Files:**
- Create: `Sources/PatataTubeKit/MediaKey.swift`
- Create: `Sources/PatataTubeKit/MediaEntryManifest.swift`
- Create: `Sources/PatataTubeKit/DownloadPlanner.swift`
- Modify: `Sources/PatataTubeKit/ByteRangeSet.swift` (add `nextCovered`)
- Test: `Tests/PatataTubeKitTests/DownloadPlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PatataTubeKitTests/DownloadPlannerTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download planner and manifest types")
struct DownloadPlannerTests {
    @Test func fourStreamsOverAnEmptyFileSplitLikeTheOldSegments() {
        let starts = DownloadPlanner.starts(
            freeHoles: [DownloadByteRange(start: 0, end: 22)],
            claims: [],
            slots: 4,
            minPiece: 1
        )
        // Claimed in this order these become 0-4, 5-10, 11-16, 17-22 — the
        // exact ranges DownloadByteRange.split produced for 23 bytes.
        #expect(starts == [0, 11, 17, 5])
    }

    @Test func freeHolesComeFirstLargestFirst() {
        let starts = DownloadPlanner.starts(
            freeHoles: [
                DownloadByteRange(start: 0, end: 9),
                DownloadByteRange(start: 50, end: 99),
            ],
            claims: [],
            slots: 2,
            minPiece: 1
        )
        #expect(starts == [50, 0])
    }

    @Test func anIdleClaimCountsAsAFreeHoleFromItsCursor() {
        let starts = DownloadPlanner.starts(
            freeHoles: [],
            claims: [.init(cursor: 300, end: 999, idle: true)],
            slots: 1,
            minPiece: 1_000
        )
        #expect(starts == [300])
    }

    @Test func aBusyClaimIsSplitOnlyWhenItsRemainderIsWorthIt() {
        let busy = DownloadPlanner.Claim(cursor: 0, end: 99, idle: false)
        #expect(DownloadPlanner.starts(freeHoles: [], claims: [busy], slots: 1, minPiece: 50) == [50])
        #expect(DownloadPlanner.starts(freeHoles: [], claims: [busy], slots: 1, minPiece: 51) == [])
    }

    @Test func noSlotsMeansNoStarts() {
        #expect(DownloadPlanner.starts(
            freeHoles: [DownloadByteRange(start: 0, end: 9)], claims: [], slots: 0, minPiece: 1
        ) == [])
    }

    @Test func keysMapToTheLegacyFilenames() {
        #expect(MediaKey.key(videoId: 812, versionId: nil) == "812")
        #expect(MediaKey.key(videoId: 812, versionId: 3) == "812:3")
        #expect(MediaKey.finishedFilename("812") == "812.mp4")
        #expect(MediaKey.finishedFilename("812:3") == "812.v3.mp4")
        #expect(MediaKey.videoId(of: "812:3") == 812)
        #expect(MediaKey.versionId(of: "812:3") == 3)
        #expect(MediaKey.versionId(of: "812") == nil)
    }

    @Test func nextCoveredFindsTheFirstStoredByteAtOrAfter() {
        var set = ByteRangeSet()
        set.insert(DownloadByteRange(start: 10, end: 19))
        set.insert(DownloadByteRange(start: 40, end: 49))
        #expect(set.nextCovered(atOrAfter: 0) == 10)
        #expect(set.nextCovered(atOrAfter: 15) == 15)
        #expect(set.nextCovered(atOrAfter: 20) == 40)
        #expect(set.nextCovered(atOrAfter: 50) == nil)
    }

    @Test func manifestRoundTripsAndReportsCompleteness() throws {
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 99))
        let manifest = MediaEntryManifest(
            key: "5",
            identity: MediaIdentity(etag: "\"e\"", totalByteCount: 100),
            committed: committed,
            pin: PinState(
                job: DownloadJobParameters(
                    remoteURL: URL(string: "https://srv.test/videos/5/stream")!,
                    streamCount: 2, previewURL: nil, showPosterKey: nil, showPosterURL: nil
                ),
                paused: true
            ),
            lastAccess: Date(timeIntervalSince1970: 1_000)
        )
        let decoded = try JSONDecoder().decode(
            MediaEntryManifest.self, from: JSONEncoder().encode(manifest)
        ).validated()
        #expect(decoded == manifest)
        #expect(decoded.isComplete)
        #expect(decoded.progress == 1)
    }

    @Test func aManifestWithBytesButNoIdentityIsCorrupt() {
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 9))
        let manifest = MediaEntryManifest(
            key: "5", identity: nil, committed: committed, pin: nil, lastAccess: Date()
        )
        #expect(throws: MediaStoreError.corruptManifest) { try manifest.validated() }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadPlannerTests`
Expected: compile failure, `cannot find 'DownloadPlanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/PatataTubeKit/MediaKey.swift`:

```swift
import Foundation

/// The cache key of a video or one of its versions (`812`, `812:3`), and the
/// names derived from it. One key is one `MediaStore` entry and one finished
/// file in the videos root.
enum MediaKey {
    static func key(videoId: Int, versionId: Int?) -> String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    static func videoId(of key: String) -> Int {
        Int(key.split(separator: ":").first ?? "") ?? 0
    }

    static func versionId(of key: String) -> Int? {
        let parts = key.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// `812.mp4` or `812.v3.mp4`, the name `CacheManager.localURL` has always used.
    static func finishedFilename(_ key: String) -> String {
        if let versionId = versionId(of: key) {
            return "\(videoId(of: key)).v\(versionId).mp4"
        }
        return "\(videoId(of: key)).mp4"
    }
}
```

`Sources/PatataTubeKit/MediaEntryManifest.swift`:

```swift
import Foundation

/// What a remote file is: its strong ETag and its size. Every byte in an entry
/// belongs to one identity; meeting a different one resets the entry.
struct MediaIdentity: Codable, Equatable, Sendable {
    let etag: String
    let totalByteCount: Int64
}

/// Everything needed to start a download again, possibly in a later process.
struct DownloadJobParameters: Codable, Equatable, Sendable {
    let remoteURL: URL
    let streamCount: Int
    let previewURL: URL?
    let showPosterKey: String?
    let showPosterURL: URL?
}

/// A pinned entry is a download: never evicted, and restarted by
/// `resumeInterrupted` unless paused.
struct PinState: Codable, Equatable, Sendable {
    let job: DownloadJobParameters
    var paused: Bool
}

/// `entry.json`. `identity` is nil only for an entry pinned before its first
/// probe (a fresh download, or a 2.8 paused download carried over by
/// `LegacyCacheMigration`); such an entry has no bytes and no `data.bin` yet.
struct MediaEntryManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = MediaEntryManifest.currentSchemaVersion
    let key: String
    var identity: MediaIdentity?
    var committed: ByteRangeSet
    var pin: PinState?
    var lastAccess: Date

    var isComplete: Bool {
        guard let identity else { return false }
        return committed.contains(DownloadByteRange(start: 0, end: identity.totalByteCount - 1))
    }

    var progress: Double {
        guard let total = identity?.totalByteCount, total > 0 else { return 0 }
        return min(Double(committed.totalBytes) / Double(total), 1)
    }

    func validated() throws -> MediaEntryManifest {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MediaStoreError.corruptManifest
        }
        if let identity {
            guard identity.totalByteCount > 0,
                  committed.runs.allSatisfy({ $0.start >= 0 && $0.end < identity.totalByteCount })
            else { throw MediaStoreError.corruptManifest }
        } else {
            guard committed.runs.isEmpty else { throw MediaStoreError.corruptManifest }
        }
        return self
    }
}

enum MediaStoreError: Error, Equatable {
    case corruptManifest
    /// A write, a sync or a rename failed even after evicting to make room.
    case storageFull
    /// A fetcher tried to commit bytes outside its claim. A programming error.
    case commitOutsideClaim
}
```

`Sources/PatataTubeKit/DownloadPlanner.swift`:

```swift
import Foundation

/// Where download fetchers should start next. Pure, so the splitting rule is
/// testable without a store; `MediaStore.claimForDownload` claims the result.
enum DownloadPlanner {
    struct Claim: Equatable, Sendable {
        let cursor: Int64
        let end: Int64
        /// A playback fetcher parked at its read-ahead lead. Its remainder is
        /// free for the taking, or a paused video would stall the download.
        let idle: Bool
    }

    /// Up to `slots` start offsets. Unclaimed holes (and idle claims' remainders)
    /// come first, largest first. Remaining slots split the largest unfetched
    /// remainder at its midpoint, as long as it is at least `2 * minPiece`.
    static func starts(
        freeHoles: [DownloadByteRange],
        claims: [Claim],
        slots: Int,
        minPiece: Int64
    ) -> [Int64] {
        guard slots > 0 else { return [] }
        var starts: [Int64] = []
        var busy: [(cursor: Int64, end: Int64)] = claims
            .filter { !$0.idle }
            .map { ($0.cursor, $0.end) }
        let open = (freeHoles + claims.filter(\.idle).map {
            DownloadByteRange(start: $0.cursor, end: $0.end)
        })
            .filter { $0.length > 0 }
            .sorted { $0.length > $1.length }

        for hole in open where starts.count < slots {
            starts.append(hole.start)
            busy.append((hole.start, hole.end))
        }
        while starts.count < slots {
            guard let index = busy.indices.max(by: {
                busy[$0].end - busy[$0].cursor < busy[$1].end - busy[$1].cursor
            }) else { break }
            let segment = busy[index]
            let remainder = segment.end - segment.cursor + 1
            guard remainder >= 2 * minPiece else { break }
            let mid = segment.cursor + remainder / 2
            busy[index] = (segment.cursor, mid - 1)
            busy.append((mid, segment.end))
            starts.append(mid)
        }
        return starts
    }
}
```

In `Sources/PatataTubeKit/ByteRangeSet.swift`, add inside `struct ByteRangeSet` (after `prefixLength`):

```swift
    /// The first stored byte at or after `offset`, or nil when none follows.
    func nextCovered(atOrAfter offset: Int64) -> Int64? {
        runs.first { $0.end >= offset }.map { max($0.start, offset) }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadPlannerTests`
Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/MediaKey.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/MediaEntryManifest.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/DownloadPlanner.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/ByteRangeSet.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadPlannerTests.swift
git commit -m "kit: media store manifest types and download planner

Groundwork for one per-video store shared by playback and downloads.
The planner reproduces the old 4-segment split for an empty file and
treats a parked playback claim's remainder as free.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: MediaStore core: entries, claims, commits, promotion

**Files:**
- Create: `Sources/PatataTubeKit/MediaStore.swift`
- Create: `Tests/PatataTubeKitTests/MediaStoreTestSupport.swift`
- Test: `Tests/PatataTubeKitTests/MediaStoreTests.swift`

- [ ] **Step 1: Write the shared test support**

`Tests/PatataTubeKitTests/MediaStoreTestSupport.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

/// Deterministic bytes, so a reassembled file can be compared to its source.
func sampleBody(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}

func temporaryVideosRoot(_ label: String = "store") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
}

/// Settable clock for LRU tests.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Claims `range`, writes `body[range]` into data.bin and commits it, the way
/// a fetcher would, then releases the claim.
func put(
    _ store: MediaStore,
    key: String,
    _ range: DownloadByteRange,
    generation: Int,
    from body: Data
) async throws {
    guard case .granted(let claim) = await store.claim(
        key: key, from: range.start, through: range.end, owner: .download, waitWithin: 0
    ), claim.end == range.end else {
        Issue.record("store refused to claim \(range)")
        return
    }
    let handle = try FileHandle(forWritingTo: store.dataURL(key: key))
    try handle.seek(toOffset: UInt64(range.start))
    try handle.write(contentsOf: body.subdata(in: Int(range.start)..<Int(range.end + 1)))
    try handle.close()
    _ = try await store.commit(key: key, claim: claim.id, generation: generation, through: range.end)
    await store.releaseClaim(key: key, id: claim.id)
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/PatataTubeKitTests/MediaStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Media store core")
struct MediaStoreTests {
    private let identity = MediaIdentity(etag: "\"e1\"", totalByteCount: 1000)
    private let body = sampleBody(1000)

    private func makeStore(tuning: MediaStore.Tuning = .init()) -> (MediaStore, URL) {
        let root = temporaryVideosRoot()
        return (MediaStore(videosRoot: root, tuning: tuning), root)
    }

    @Test func openCreatesAnEntryForTheIdentity() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        let manifest = try #require(await store.manifest(key: "1"))
        #expect(manifest.identity == identity)
        #expect(manifest.committed.runs.isEmpty)
        #expect(manifest.pin == nil)
        #expect(FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
        #expect(await store.verifiedIdentity(key: "1")?.identity == identity)
    }

    @Test func availabilityIsTheContiguousCommittedRun() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        try await put(store, key: "1", DownloadByteRange(start: 200, end: 299), generation: generation, from: body)
        #expect(await store.available(key: "1", from: 0)?.bytes == 100)
        #expect(await store.available(key: "1", from: 50)?.bytes == 50)
        #expect(await store.available(key: "1", from: 100)?.bytes == 0)
        #expect(await store.available(key: "1", from: 250)?.bytes == 50)
        #expect(await store.available(key: "missing", from: 0) == nil)
    }

    @Test func aLaterClaimShortensTheOneItLandsIn() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let first) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("first claim refused"); return }
        #expect(first.end == 999)
        guard case .granted(let second) = await store.claim(
            key: "1", from: 500, through: 999, owner: .playback, waitWithin: 0
        ) else { Issue.record("second claim refused"); return }
        #expect(second.end == 999)
        let claims = await store.claims(key: "1")
        #expect(claims.map(\.cursor) == [0, 500])
        #expect(claims.map(\.end) == [499, 999])
    }

    @Test func aClaimStopsAtCommittedAndClaimedBytes() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 600, end: 699), generation: generation, from: body)
        guard case .granted(let head) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(head.end == 599)
        #expect(await store.claim(key: "1", from: 650, through: 999, owner: .download, waitWithin: 0)
                == .alreadyCommitted)
        guard case .granted(let tail) = await store.claim(
            key: "1", from: 700, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(tail.end == 999)
    }

    @Test func aFetcherCloseBehindCoversTheByte() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        _ = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        guard case .covered(let holder, _) = await store.claim(
            key: "1", from: 50, through: 999, owner: .playback, waitWithin: 100
        ) else { Issue.record("expected covered"); return }
        #expect(holder.cursor == 0)
        #expect(await store.claims(key: "1").count == 1)
    }

    @Test func anIdleClaimIsTakenOverAtItsCursor() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let parked) = await store.claim(
            key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0
        ) else { Issue.record("refused"); return }
        await store.setClaimIdle(key: "1", id: parked.id, idle: true)
        guard case .granted(let taken) = await store.claim(
            key: "1", from: 0, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("idle claim was not taken over"); return }
        #expect(taken.cursor == 0 && taken.end == 999)
        #expect(await store.claimSnapshot(key: "1", id: parked.id) == nil)
    }

    @Test func aWaiterIsWokenByACommit() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        let seen = await store.version(key: "1")
        let woke = Task { await store.waitForChange(key: "1", after: seen); return true }
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 9), generation: generation, from: body)
        #expect(await woke.value)
    }

    @Test func aCancelledWaiterReturns() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: identity)
        let seen = await store.version(key: "1")
        let waiter = Task { await store.waitForChange(key: "1", after: seen) }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await waiter.value
    }

    @Test func aCommitFromAnOldGenerationIsStale() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(
            key: "1", from: 0, through: 99, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        #expect(try await store.commit(key: "1", claim: claim.id, generation: generation + 1, through: 9) == .stale)
        await #expect(throws: MediaStoreError.commitOutsideClaim) {
            _ = try await store.commit(key: "1", claim: claim.id, generation: generation, through: 100)
        }
    }

    @Test func aDifferentIdentityResetsTheEntry() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        let changed = MediaIdentity(etag: "\"e2\"", totalByteCount: 2000)
        let next = try await store.open(key: "1", identity: changed)
        #expect(next != generation)
        #expect(await store.available(key: "1", from: 0)?.bytes == 0)
        #expect(await store.manifest(key: "1")?.identity == changed)
    }

    @Test func closingTheLastHolePromotesTheFile() async throws {
        let (store, _) = makeStore()
        let generation = try await store.open(key: "7:2", identity: identity)
        try await put(store, key: "7:2", DownloadByteRange(start: 0, end: 499), generation: generation, from: body)
        guard case .granted(let last) = await store.claim(
            key: "7:2", from: 500, through: 999, owner: .download, waitWithin: 0
        ) else { Issue.record("refused"); return }
        let handle = try FileHandle(forWritingTo: store.dataURL(key: "7:2"))
        try handle.seek(toOffset: 500)
        try handle.write(contentsOf: body.subdata(in: 500..<1000))
        try handle.close()
        #expect(try await store.commit(key: "7:2", claim: last.id, generation: generation, through: 999) == .promoted)
        let finished = store.finishedURL(key: "7:2")
        #expect(finished.lastPathComponent == "7.v2.mp4")
        #expect(try Data(contentsOf: finished) == body)
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "7:2").path))
        #expect(await store.manifest(key: "7:2") == nil)
    }

    @Test func committedRangesSurviveANewStore() async throws {
        var tuning = MediaStore.Tuning()
        tuning.manifestFlushBytes = 1
        let (store, root) = makeStore(tuning: tuning)
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        let reopened = MediaStore(videosRoot: root)
        let manifest = try #require(await reopened.manifest(key: "1"))
        #expect(manifest.committed.totalBytes == 100)
        #expect(await reopened.verifiedIdentity(key: "1") == nil, "a new process probes again")
    }

    @Test func claimForDownloadSplitsAnEmptyFileIntoFour() async throws {
        let (store, _) = makeStore()
        _ = try await store.open(key: "1", identity: MediaIdentity(etag: "\"e\"", totalByteCount: 23))
        let claims = await store.claimForDownload(key: "1", slots: 4, minPiece: 1)
        #expect(claims.map { "\($0.cursor)-\($0.end)" }.sorted() == ["0-4", "11-16", "17-22", "5-10"])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaStoreTests`
Expected: compile failure, `cannot find 'MediaStore' in scope`.

- [ ] **Step 4: Implement**

`Sources/PatataTubeKit/MediaStore.swift`:

```swift
import Foundation

struct ClaimID: Hashable, Sendable {
    let raw: UInt64
}

enum ClaimOwner: String, Sendable {
    case playback
    case download
}

struct ClaimSnapshot: Equatable, Sendable {
    let id: ClaimID
    let owner: ClaimOwner
    /// The next byte this claim's fetcher will commit.
    let cursor: Int64
    let end: Int64
    let idle: Bool
}

enum ClaimResult: Equatable, Sendable {
    case granted(ClaimSnapshot)
    case alreadyCommitted
    /// A fetcher close behind is about to commit this byte: wait for a change
    /// after `version` instead of fetching it twice.
    case covered(ClaimSnapshot, version: UInt64)
    case noEntry
}

enum CommitResult: Equatable, Sendable {
    /// Keep going. The claim now ends at this byte; it may have been shortened.
    case continueThrough(Int64)
    /// The claim is over: it reached its end, or someone took over the rest.
    case finished
    /// That commit completed the file, which is now the finished mp4.
    case promoted
    /// The entry was reset or deleted; these bytes belong to nothing.
    case stale
}

struct Availability: Equatable, Sendable {
    let generation: Int
    /// Committed bytes from the asked offset onward, contiguous.
    let bytes: Int64
}

/// One byte store per video, shared by the stream proxy and downloads.
///
/// An entry is `Documents/videos/.store/<key>/` holding a sparse `data.bin`
/// and `entry.json` (`MediaEntryManifest`). In memory each entry also has
/// **claims**: ranges a fetcher is downloading right now. Claims never overlap,
/// so a byte is fetched once even while a video is watched and downloaded at
/// the same time. Fetchers write `data.bin` through their own handles, then
/// `commit`; only committed bytes are ever served. Whatever commit closes the
/// last hole renames `data.bin` to the finished `videos/<id>.mp4`.
///
/// Every change bumps a per-key version and wakes `waitForChange` callers;
/// that is how a reader waits for a fetcher and a download wakes for a hole.
public actor MediaStore {
    public static let defaultBudgetBytes: Int64 = 50 * 1024 * 1024 * 1024

    struct Tuning: Sendable {
        /// Rewrite `entry.json` at most this often, or after this many new
        /// bytes, whichever comes first: a crash loses a bounded amount.
        var manifestFlushInterval: TimeInterval = 2
        var manifestFlushBytes: Int64 = 1_048_576
    }

    private final class Entry {
        var manifest: MediaEntryManifest
        var generation: Int
        var claims: [ClaimID: Claim] = [:]
        var readers = 0
        var deleteWhenIdle = false
        var promoted = false
        /// The identity was confirmed with the server in this process.
        var verified = false
        var dirtyBytes: Int64 = 0
        var lastFlush: Date

        init(manifest: MediaEntryManifest, generation: Int, lastFlush: Date) {
            self.manifest = manifest
            self.generation = generation
            self.lastFlush = lastFlush
        }
    }

    private struct Claim {
        let id: ClaimID
        let owner: ClaimOwner
        var cursor: Int64
        var end: Int64
        var idle = false

        var snapshot: ClaimSnapshot {
            ClaimSnapshot(id: id, owner: owner, cursor: cursor, end: end, idle: idle)
        }
    }

    nonisolated let videosRoot: URL
    public nonisolated let storeRoot: URL
    private let budgetBytes: Int64
    private let tuning: Tuning
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var versions: [String: UInt64] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var nextClaimID: UInt64 = 0
    private var nextGenerationValue = 0
    private var loadedAll = false

    init(
        videosRoot: URL,
        budgetBytes: Int64 = MediaStore.defaultBudgetBytes,
        tuning: Tuning = Tuning(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.videosRoot = videosRoot
        self.storeRoot = Self.storeRoot(videosRoot: videosRoot)
        self.budgetBytes = budgetBytes
        self.tuning = tuning
        self.now = now
        Self.prepareRoot(storeRoot)
    }

    // MARK: - Paths

    nonisolated static func storeRoot(videosRoot: URL) -> URL {
        videosRoot.appendingPathComponent(".store", isDirectory: true)
    }

    nonisolated func entryDir(key: String) -> URL {
        storeRoot.appendingPathComponent(key, isDirectory: true)
    }

    nonisolated func dataURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("data.bin")
    }

    nonisolated func finishedURL(key: String) -> URL {
        videosRoot.appendingPathComponent(MediaKey.finishedFilename(key))
    }

    nonisolated static func manifestURL(storeRoot: URL, key: String) -> URL {
        storeRoot.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("entry.json")
    }

    private nonisolated static func prepareRoot(_ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root
        try? directory.setResourceValues(values)
    }

    // MARK: - Manifests on disk

    /// Every readable manifest. Synchronous, for `CacheManager`'s launch-time
    /// mirror, which runs before this actor touches the disk.
    nonisolated static func loadManifests(storeRoot: URL) -> [MediaEntryManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: storeRoot, includingPropertiesForKeys: nil
        )) ?? []
        return dirs.compactMap { readManifest(storeRoot: storeRoot, key: $0.lastPathComponent) }
    }

    nonisolated static func readManifest(storeRoot: URL, key: String) -> MediaEntryManifest? {
        guard let data = try? Data(contentsOf: manifestURL(storeRoot: storeRoot, key: key)),
              let manifest = try? JSONDecoder().decode(MediaEntryManifest.self, from: data).validated(),
              manifest.key == key
        else { return nil }
        return manifest
    }

    nonisolated static func writeManifest(_ manifest: MediaEntryManifest, storeRoot: URL) throws {
        let dir = storeRoot.appendingPathComponent(manifest.key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest)
            .write(to: manifestURL(storeRoot: storeRoot, key: manifest.key), options: .atomic)
    }

    // MARK: - Entries

    private func nextGeneration() -> Int {
        nextGenerationValue += 1
        return nextGenerationValue
    }

    /// The in-memory entry, loading it from disk on first use. An unreadable
    /// entry is deleted: its bytes cannot be trusted without its manifest.
    private func entry(_ key: String) -> Entry? {
        if let entry = entries[key] { return entry }
        let dir = entryDir(key: key)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let manifest = Self.readManifest(storeRoot: storeRoot, key: key),
              manifest.identity == nil
                || FileManager.default.fileExists(atPath: dataURL(key: key).path)
        else {
            DevLog.event(.cache, "store entry unreadable, removed", ["key": key])
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        let entry = Entry(manifest: manifest, generation: nextGeneration(), lastFlush: now())
        entries[key] = entry
        return entry
    }

    private func loadAll() {
        guard !loadedAll else { return }
        loadedAll = true
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: storeRoot, includingPropertiesForKeys: nil
        )) ?? []
        for dir in dirs { _ = entry(dir.lastPathComponent) }
    }

    func manifest(key: String) -> MediaEntryManifest? {
        guard let entry = entry(key), !entry.promoted else { return nil }
        return entry.manifest
    }

    func version(key: String) -> UInt64 {
        versions[key] ?? 0
    }

    /// The identity and generation already confirmed with the server in this
    /// process, if any. A new process always probes once.
    func verifiedIdentity(key: String) -> (identity: MediaIdentity, generation: Int)? {
        guard let entry = entry(key), entry.verified, !entry.promoted,
              let identity = entry.manifest.identity
        else { return nil }
        return (identity, entry.generation)
    }

    /// Forgets that the identity was confirmed, so the next user probes again.
    func invalidate(key: String) {
        entry(key)?.verified = false
    }

    /// Makes `key` an entry for `identity` and returns the generation every
    /// fetcher and reader must carry. Creates the entry, adopts an
    /// identity-less one, or resets one that holds a different identity.
    @discardableResult
    func open(key: String, identity: MediaIdentity) throws -> Int {
        if entries[key] == nil,
           FileManager.default.fileExists(atPath: finishedURL(key: key).path) {
            // Finished while nobody held an entry: answer for the mp4.
            var committed = ByteRangeSet()
            committed.insert(DownloadByteRange(start: 0, end: identity.totalByteCount - 1))
            let entry = Entry(
                manifest: MediaEntryManifest(
                    key: key, identity: identity, committed: committed, pin: nil, lastAccess: now()
                ),
                generation: nextGeneration(),
                lastFlush: now()
            )
            entry.promoted = true
            entry.verified = true
            entries[key] = entry
            return entry.generation
        }
        let entry = try self.entry(key) ?? create(key: key, identity: identity)
        if entry.manifest.identity == nil {
            try createDataFile(key: key)
            entry.manifest.identity = identity
            try flush(key, entry)
        } else if entry.manifest.identity != identity, !entry.promoted {
            try reset(key, entry, to: identity)
        }
        entry.verified = true
        return entry.generation
    }

    private func create(key: String, identity: MediaIdentity?) throws -> Entry {
        let manifest = MediaEntryManifest(
            key: key, identity: identity, committed: ByteRangeSet(), pin: nil, lastAccess: now()
        )
        do {
            try Self.writeManifest(manifest, storeRoot: storeRoot)
            if identity != nil { try createDataFile(key: key) }
        } catch {
            try? FileManager.default.removeItem(at: entryDir(key: key))
            throw MediaStoreError.storageFull
        }
        let entry = Entry(manifest: manifest, generation: nextGeneration(), lastFlush: now())
        entries[key] = entry
        return entry
    }

    private func createDataFile(key: String) throws {
        let url = dataURL(key: key)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw MediaStoreError.storageFull
        }
    }

    /// The server now has a different file under this key. Everything stored
    /// is wrong: open readers see a new generation and end, fetchers' commits
    /// turn stale.
    private func reset(_ key: String, _ entry: Entry, to identity: MediaIdentity) throws {
        DevLog.event(.cache, "store entry reset: identity changed", [
            "key": key,
            "old_etag": entry.manifest.identity?.etag ?? "-",
            "new_etag": identity.etag,
            "old_total": entry.manifest.identity.map { "\($0.totalByteCount)" } ?? "-",
            "new_total": "\(identity.totalByteCount)",
        ])
        entry.generation = nextGeneration()
        entry.claims.removeAll()
        entry.manifest.committed = ByteRangeSet()
        entry.manifest.identity = identity
        entry.dirtyBytes = 0
        try createDataFile(key: key)
        try flush(key, entry)
        bump(key)
    }

    // MARK: - Claims

    /// Asks to fetch from `start` toward `end`. The grant stops before the
    /// next committed or claimed byte. A claim already covering `start` wins
    /// when its fetcher is at most `waitWithin` behind and not idle;
    /// otherwise it is shortened to end just before `start`.
    func claim(
        key: String,
        from start: Int64,
        through end: Int64,
        owner: ClaimOwner,
        waitWithin: Int64
    ) -> ClaimResult {
        guard let entry = entry(key) else { return .noEntry }
        if entry.promoted { return .alreadyCommitted }
        guard let total = entry.manifest.identity?.totalByteCount,
              start >= 0, start < total, end >= start
        else { return .noEntry }
        if entry.manifest.committed.contains(DownloadByteRange(start: start, end: start)) {
            return .alreadyCommitted
        }
        if let holder = entry.claims.values.first(where: { $0.cursor <= start && start <= $0.end }) {
            if !holder.idle, start - holder.cursor <= waitWithin {
                return .covered(holder.snapshot, version: version(key: key))
            }
            shorten(entry, holder.id, toEndBefore: start)
        }
        var granted = min(end, total - 1)
        if let next = entry.manifest.committed.nextCovered(atOrAfter: start) {
            granted = min(granted, next - 1)
        }
        if let next = entry.claims.values.map(\.cursor).filter({ $0 > start }).min() {
            granted = min(granted, next - 1)
        }
        nextClaimID += 1
        let claim = Claim(id: ClaimID(raw: nextClaimID), owner: owner, cursor: start, end: granted)
        entry.claims[claim.id] = claim
        bump(key)
        return .granted(claim.snapshot)
    }

    private func shorten(_ entry: Entry, _ id: ClaimID, toEndBefore start: Int64) {
        guard var claim = entry.claims[id] else { return }
        claim.end = start - 1
        entry.claims[id] = claim.end < claim.cursor ? nil : claim
    }

    func claimSnapshot(key: String, id: ClaimID) -> ClaimSnapshot? {
        entries[key]?.claims[id]?.snapshot
    }

    func claims(key: String) -> [ClaimSnapshot] {
        (entries[key]?.claims.values.map(\.snapshot) ?? []).sorted { $0.cursor < $1.cursor }
    }

    func releaseClaim(key: String, id: ClaimID) {
        guard entries[key]?.claims.removeValue(forKey: id) != nil else { return }
        bump(key)
    }

    /// Marks a playback claim parked at its read-ahead lead (or awake again).
    /// A download may take over an idle claim's remainder.
    func setClaimIdle(key: String, id: ClaimID, idle: Bool) {
        guard let entry = entries[key], var claim = entry.claims[id], claim.idle != idle else { return }
        claim.idle = idle
        entry.claims[id] = claim
        bump(key)
    }

    /// Claims where up to `slots` more download fetchers should run, per
    /// `DownloadPlanner`. Atomic, so two planners can never pick the same byte.
    func claimForDownload(key: String, slots: Int, minPiece: Int64) -> [ClaimSnapshot] {
        guard slots > 0, let entry = entry(key), !entry.promoted,
              let total = entry.manifest.identity?.totalByteCount
        else { return [] }
        var covered = entry.manifest.committed
        for claim in entry.claims.values {
            covered.insert(DownloadByteRange(start: claim.cursor, end: claim.end))
        }
        let starts = DownloadPlanner.starts(
            freeHoles: covered.missingRanges(in: DownloadByteRange(start: 0, end: total - 1)),
            claims: entry.claims.values.map { .init(cursor: $0.cursor, end: $0.end, idle: $0.idle) },
            slots: slots,
            minPiece: minPiece
        )
        var granted: [ClaimID] = []
        for start in starts {
            if case .granted(let snapshot) = claim(
                key: key, from: start, through: total - 1, owner: .download, waitWithin: 0
            ) {
                granted.append(snapshot.id)
            }
        }
        // Re-read: each later claim shortened the one it landed in.
        return granted.compactMap { claimSnapshot(key: key, id: $0) }
    }

    // MARK: - Commits

    /// Records that the claim's bytes from its cursor through `lastByte` are
    /// in `data.bin`. The caller wrote them first.
    func commit(
        key: String,
        claim id: ClaimID,
        generation: Int,
        through lastByte: Int64
    ) throws -> CommitResult {
        guard let entry = entries[key] else {
            return FileManager.default.fileExists(atPath: finishedURL(key: key).path)
                ? .finished : .stale
        }
        if entry.promoted { return .finished }
        guard entry.generation == generation else { return .stale }
        guard var claim = entry.claims[id] else { return .finished }
        guard lastByte >= claim.cursor, lastByte <= claim.end else {
            throw MediaStoreError.commitOutsideClaim
        }
        let range = DownloadByteRange(start: claim.cursor, end: lastByte)
        entry.manifest.committed.insert(range)
        entry.dirtyBytes += range.length
        entry.manifest.lastAccess = now()
        claim.cursor = lastByte + 1
        if entry.manifest.isComplete {
            entry.claims.removeAll()
            try promote(key, entry)
            bump(key)
            return .promoted
        }
        let done = claim.cursor > claim.end
        entry.claims[id] = done ? nil : claim
        try flushIfDue(key, entry)
        bump(key)
        return done ? .finished : .continueThrough(claim.end)
    }

    func available(key: String, from offset: Int64) -> Availability? {
        guard let entry = entry(key), let total = entry.manifest.identity?.totalByteCount else {
            return nil
        }
        if entry.promoted {
            return Availability(generation: entry.generation, bytes: max(total - offset, 0))
        }
        return Availability(
            generation: entry.generation,
            bytes: entry.manifest.committed.prefixLength(from: offset, limit: total)
        )
    }

    // MARK: - Durability and promotion

    private func flushIfDue(_ key: String, _ entry: Entry) throws {
        let due = entry.dirtyBytes >= tuning.manifestFlushBytes
            || now().timeIntervalSince(entry.lastFlush) >= tuning.manifestFlushInterval
        if due { try flush(key, entry) }
    }

    /// Data first, manifest second: a crash can lose bytes the manifest never
    /// recorded, but the manifest never names bytes that are not on disk.
    private func flush(_ key: String, _ entry: Entry) throws {
        do {
            if entry.manifest.identity != nil, entry.dirtyBytes > 0 {
                let handle = try FileHandle(forWritingTo: dataURL(key: key))
                defer { try? handle.close() }
                try handle.synchronize()
            }
            try Self.writeManifest(entry.manifest, storeRoot: storeRoot)
        } catch {
            throw MediaStoreError.storageFull
        }
        entry.dirtyBytes = 0
        entry.lastFlush = now()
    }

    /// Renames the complete `data.bin` to the finished mp4. Open read handles
    /// keep working (the inode survives the rename); new requests are served
    /// from the mp4.
    private func promote(_ key: String, _ entry: Entry) throws {
        let source = dataURL(key: key)
        let destination = finishedURL(key: key)
        do {
            let handle = try FileHandle(forWritingTo: source)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            DevLog.event(.cache, "store promotion failed", ["key": key, "err": "\(error)"])
            throw MediaStoreError.storageFull
        }
        try? FileManager.default.removeItem(at: entryDir(key: key))
        entry.promoted = true
        DevLog.event(.cache, "store entry promoted", [
            "key": key,
            "bytes": entry.manifest.identity.map { "\($0.totalByteCount)" } ?? "-",
            "pinned": "\(entry.manifest.pin != nil)",
        ])
        if entry.readers == 0 { entries[key] = nil }
    }

    // MARK: - Change notification

    /// Returns once `key` changed after `seen` (a commit, a claim taken or
    /// released, a reset, a deletion), or the task is cancelled.
    func waitForChange(key: String, after seen: UInt64) async {
        guard version(key: key) == seen else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[key, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: id) }
        }
    }

    private func cancelWaiter(key: String, id: UUID) {
        waiters[key]?.removeValue(forKey: id)?.resume()
    }

    private func bump(_ key: String) {
        versions[key, default: 0] &+= 1
        guard let woken = waiters.removeValue(forKey: key) else { return }
        for continuation in woken.values { continuation.resume() }
    }
}
```

Note: if Swift 6.0 rejects mutating `waiters` inside the `withCheckedContinuation` body (it should inherit the actor's isolation through its `isolation:` parameter), move the registration into a private actor method `register(key:id:continuation:)` and call it from the body. Keep the `Task.isCancelled` check.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaStoreTests`
Expected: all 14 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/MediaStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaStoreTestSupport.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaStoreTests.swift
git commit -m "kit: MediaStore core — entries, claims, commits, promotion

One sparse entry per video with non-overlapping in-memory claims, so a
byte is fetched once whether it is being watched, downloaded or both.
The commit that closes the last hole renames data.bin to the mp4.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: MediaStore lifecycle: readers, pins, deletion, LRU

**Files:**
- Modify: `Sources/PatataTubeKit/MediaStore.swift` (append an extension; one line in `flush`)
- Test: `Tests/PatataTubeKitTests/MediaStoreLifecycleTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PatataTubeKitTests/MediaStoreLifecycleTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Media store lifecycle")
struct MediaStoreLifecycleTests {
    private let identity = MediaIdentity(etag: "\"e1\"", totalByteCount: 1000)
    private let body = sampleBody(1000)
    private let job = DownloadJobParameters(
        remoteURL: URL(string: "https://srv.test/videos/1/stream")!,
        streamCount: 1, previewURL: nil, showPosterKey: nil, showPosterURL: nil
    )

    @Test func discardWaitsForTheLastReader() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await store.beginRead(key: "1")
        await store.discard(key: "1")
        #expect(FileManager.default.fileExists(atPath: store.entryDir(key: "1").path))
        await store.endRead(key: "1")
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "1").path))
        #expect(await store.manifest(key: "1") == nil)
    }

    @Test func pinningAgainCancelsADeferredDelete() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await store.beginRead(key: "1")
        await store.discard(key: "1")
        await store.setPin(key: "1", pin: PinState(job: job, paused: false))
        await store.endRead(key: "1")
        #expect(await store.manifest(key: "1")?.pin?.paused == false)
    }

    @Test func pinnedAndReadEntriesAreNeverEvicted() async throws {
        let clock = TestNow()
        let store = MediaStore(videosRoot: temporaryVideosRoot(), budgetBytes: 150, now: { clock.date })
        for key in ["pinned", "read", "old", "new"] {
            let generation = try await store.open(key: key, identity: identity)
            try await put(store, key: key, DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
            clock.advance(10)
        }
        await store.setPin(key: "pinned", pin: PinState(job: job, paused: true))
        await store.beginRead(key: "read")
        await store.enforceBudget()
        // Unpinned total 300 > 150: "read" is busy, so the oldest idle one goes first.
        #expect(await store.manifest(key: "pinned") != nil)
        #expect(await store.manifest(key: "read") != nil)
        #expect(await store.manifest(key: "old") == nil)
        #expect(await store.manifest(key: "new") == nil)
    }

    @Test func storageFailureEvictsTheOldestOtherUnpinnedEntry() async throws {
        let clock = TestNow()
        let store = MediaStore(videosRoot: temporaryVideosRoot(), now: { clock.date })
        for key in ["a", "b", "c"] {
            _ = try await store.open(key: key, identity: identity)
            clock.advance(10)
        }
        await store.setPin(key: "a", pin: PinState(job: job, paused: false))
        #expect(await store.evictForStorageFailure(excluding: "c"))
        #expect(await store.manifest(key: "a") != nil)
        #expect(await store.manifest(key: "b") == nil)
        #expect(await store.manifest(key: "c") != nil)
        #expect(await store.evictForStorageFailure(excluding: "c") == false)
    }

    @Test func pinningBeforeTheProbeCreatesAnEntryOpenAdopts() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        await store.setPin(key: "1", pin: PinState(job: job, paused: false))
        let pinned = try #require(await store.manifest(key: "1"))
        #expect(pinned.identity == nil)
        #expect(!FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
        _ = try await store.open(key: "1", identity: identity)
        #expect(await store.manifest(key: "1")?.identity == identity)
        #expect(await store.manifest(key: "1")?.pin == pinned.pin)
        #expect(FileManager.default.fileExists(atPath: store.dataURL(key: "1").path))
    }

    @Test func openOverAFinishedFileReportsEverythingAvailable() async throws {
        let root = temporaryVideosRoot()
        let store = MediaStore(videosRoot: root)
        try body.write(to: store.finishedURL(key: "1"))
        let generation = try await store.open(key: "1", identity: identity)
        #expect(await store.available(key: "1", from: 400) == Availability(generation: generation, bytes: 600))
        #expect(await store.claim(key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0)
                == .alreadyCommitted)
        let handle = try #require(await store.openReadHandle(key: "1"))
        try handle.seek(toOffset: 10)
        #expect(try handle.read(upToCount: 5) == body.subdata(in: 10..<15))
    }

    @Test func promoteIfCompleteSeesAFinishedFile() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 99), generation: generation, from: body)
        #expect(try await store.promoteIfComplete(key: "1") == false)
        try body.write(to: store.finishedURL(key: "2"))
        #expect(try await store.promoteIfComplete(key: "2"))
    }

    @Test func discardAllForAVideoKeepsOtherVideos() async throws {
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        for key in ["23", "23:4", "24:1"] { _ = try await store.open(key: key, identity: identity) }
        await store.discardAll(videoId: 23)
        #expect(await store.manifest(key: "23") == nil)
        #expect(await store.manifest(key: "23:4") == nil)
        #expect(await store.manifest(key: "24:1") != nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaStoreLifecycleTests`
Expected: compile failure, `value of type 'MediaStore' has no member 'beginRead'`.

- [ ] **Step 3: Implement**

Append to the end of `Sources/PatataTubeKit/MediaStore.swift`:

```swift
// MARK: - Readers, pins, deletion, eviction

extension MediaStore {
    /// An open proxy response started reading `key`. While any are open the
    /// entry is never evicted, and a discard waits for the last one.
    func beginRead(key: String) {
        guard let entry = entry(key) else { return }
        entry.readers += 1
        entry.manifest.lastAccess = now()
    }

    func endRead(key: String) {
        guard let entry = entries[key] else { return }
        entry.readers = max(entry.readers - 1, 0)
        guard entry.readers == 0 else { return }
        if entry.deleteWhenIdle {
            delete(key)
        } else if entry.promoted {
            entries[key] = nil
        } else {
            try? flush(key, entry)
            enforceBudget()
        }
    }

    /// A handle on the bytes: `data.bin`, or the mp4 once promoted.
    func openReadHandle(key: String) -> FileHandle? {
        guard let entry = entry(key), !entry.promoted else {
            return try? FileHandle(forReadingFrom: finishedURL(key: key))
        }
        return try? FileHandle(forReadingFrom: dataURL(key: key))
    }

    /// `nil` unpins. Pinning a key that has no entry yet creates an
    /// identity-less one; the job's probe fills it in through `open`.
    func setPin(key: String, pin: PinState?) {
        let existing = entry(key)
        guard let entry = existing ?? (pin == nil ? nil : try? create(key: key, identity: nil)) else {
            return
        }
        entry.manifest.pin = pin
        if pin != nil { entry.deleteWhenIdle = false }
        try? flush(key, entry)
        bump(key)
    }

    /// Unpins and deletes the entry, or, while a player response still
    /// reads it, deletes it when the last one ends, so cancelling a
    /// download never cuts off what is playing.
    func discard(key: String) {
        guard let entry = entry(key) else { return }
        entry.manifest.pin = nil
        guard entry.readers == 0 else {
            entry.deleteWhenIdle = true
            DevLog.event(.cache, "store entry delete deferred: still read", [
                "key": key, "readers": "\(entry.readers)",
            ])
            return
        }
        delete(key)
    }

    func discardAll(videoId: Int) {
        loadAll()
        for key in Array(entries.keys) where MediaKey.videoId(of: key) == videoId {
            discard(key: key)
        }
    }

    func discardAll() {
        loadAll()
        for key in Array(entries.keys) { discard(key: key) }
    }

    func readers(key: String) -> Int {
        entries[key]?.readers ?? 0
    }

    /// For a job that finds nothing left to claim. True when the finished mp4
    /// exists, promoting a complete entry whose earlier rename failed.
    func promoteIfComplete(key: String) throws -> Bool {
        if FileManager.default.fileExists(atPath: finishedURL(key: key).path) { return true }
        guard let entry = entry(key), entry.manifest.isComplete else { return false }
        if !entry.promoted {
            try promote(key, entry)
            bump(key)
        }
        return true
    }

    /// Evicts least recently used **unpinned** partial entries until they fit
    /// the budget. Pinned entries (downloads), entries being read or fetched,
    /// and finished mp4s are never touched. Sizes come from the manifests,
    /// so a sweep never walks the disk.
    func enforceBudget() {
        loadAll()
        let unpinned = entries.filter { $0.value.manifest.pin == nil && !$0.value.promoted }
        var total = unpinned.values.reduce(Int64(0)) { $0 + $1.manifest.committed.totalBytes }
        guard total > budgetBytes else { return }
        DevLog.event(.cache, "store over budget", [
            "total": "\(total)", "budget": "\(budgetBytes)", "entries": "\(unpinned.count)",
        ])
        let candidates = unpinned
            .filter { $0.value.readers == 0 && $0.value.claims.isEmpty }
            .sorted { $0.value.manifest.lastAccess < $1.value.manifest.lastAccess }
        for (key, entry) in candidates {
            guard total > budgetBytes else { break }
            total -= entry.manifest.committed.totalBytes
            delete(key)
            DevLog.event(.cache, "store evicted", [
                "key": key, "bytes": "\(entry.manifest.committed.totalBytes)", "remaining": "\(total)",
            ])
        }
    }

    /// Frees one idle unpinned entry other than `excluded` after a write
    /// failed. False when there is nothing to free.
    func evictForStorageFailure(excluding excluded: String) -> Bool {
        loadAll()
        let victim = entries
            .filter {
                $0.key != excluded && $0.value.manifest.pin == nil && !$0.value.promoted
                    && $0.value.readers == 0 && $0.value.claims.isEmpty
            }
            .min { $0.value.manifest.lastAccess < $1.value.manifest.lastAccess }
        guard let victim else {
            DevLog.event(.cache, "storage-failure eviction found nothing to free", ["excluded": excluded])
            return false
        }
        delete(victim.key)
        DevLog.event(.cache, "evicted for storage failure", ["key": victim.key, "excluded": excluded])
        return true
    }

    private func delete(_ key: String) {
        entries[key] = nil
        try? FileManager.default.removeItem(at: entryDir(key: key))
        bump(key)
    }
}
```

`delete`, `create`, `promote`, `flush`, `entry`, `loadAll`, `bump` and `now` are `private` in the actor body. A same-file extension can use them in Swift 5+, so leave them `private`.

Also in `flush(_:_:)`, after `entry.lastFlush = now()`, add:

```swift
        if entry.manifest.pin == nil { enforceBudget() }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MediaStoreLifecycleTests|MediaStoreTests"`
Expected: all 22 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/MediaStore.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MediaStoreLifecycleTests.swift
git commit -m "kit: MediaStore readers, pins, deferred delete and LRU

Pinned entries (downloads) and entries a player is reading are never
evicted; cancelling a download mid-watch defers the delete to the last
reader so playback is not cut off.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: First-launch migration of the 2.8 caches

**Files:**
- Create: `Sources/PatataTubeKit/LegacyCacheMigration.swift`
- Test: `Tests/PatataTubeKitTests/LegacyCacheMigrationTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PatataTubeKitTests/LegacyCacheMigrationTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Legacy cache migration")
struct LegacyCacheMigrationTests {
    private func paused(_ id: Int, version: Int? = nil, url: String) -> PausedDownload {
        PausedDownload(
            videoID: id, versionID: version, remoteURL: URL(string: url)!, streamCount: 3,
            previewURL: URL(string: "https://srv.test/p/\(id).jpg"), showPosterKey: nil,
            showPosterURL: nil, progress: 0.5, transferredByteCount: 50, totalByteCount: 100
        )
    }

    @Test func deletesTheOldStreamCachePartFilesAndResumeData() throws {
        let videos = temporaryVideosRoot("migrate")
        let stream = temporaryVideosRoot("old-stream")
        let fm = FileManager.default
        try fm.createDirectory(at: stream.appendingPathComponent("mp4/3"), withIntermediateDirectories: true)
        try fm.createDirectory(at: videos.appendingPathComponent(".downloads/9"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: videos.appendingPathComponent("9.resume"))
        try Data("x".utf8).write(to: videos.appendingPathComponent("9.mp4"))

        LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: stream, now: Date())

        #expect(!fm.fileExists(atPath: stream.path))
        #expect(!fm.fileExists(atPath: videos.appendingPathComponent(".downloads").path))
        #expect(!fm.fileExists(atPath: videos.appendingPathComponent("9.resume").path))
        #expect(fm.fileExists(atPath: videos.appendingPathComponent("9.mp4").path))
    }

    @Test func pausedDownloadsBecomePausedPinnedEntriesFromZero() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        legacy.insert(paused(6, version: 2, url: "https://srv.test/videos/6/stream?version_id=2"))
        legacy.insert(paused(7, url: "https://srv.test/videos/7/master.m3u8"))

        let converted = LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date())

        #expect(Set(converted) == ["5", "6:2"])
        let manifests = MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: videos))
        let five = try #require(manifests.first { $0.key == "5" })
        #expect(five.identity == nil)
        #expect(five.committed.runs.isEmpty)
        #expect(five.pin?.paused == true)
        #expect(five.pin?.job.streamCount == 3)
        #expect(five.pin?.job.previewURL == URL(string: "https://srv.test/p/5.jpg"))
        #expect(PausedDownloadStore(root: videos).entries.isEmpty)
        // The HLS one is dropped and recorded for re-download, as before.
        #expect(PausedDownloadStore.droppedHLSVideoIDs(root: videos) == [7])
    }

    @Test func skipsAPausedDownloadWhoseFileLanded() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        try Data("x".utf8).write(to: videos.appendingPathComponent("5.mp4"))
        #expect(LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date()).isEmpty)
    }

    @Test func runningTwiceIsHarmless() throws {
        let videos = temporaryVideosRoot("migrate")
        var legacy = PausedDownloadStore(root: videos)
        legacy.insert(paused(5, url: "https://srv.test/videos/5/stream"))
        _ = LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date())
        #expect(LegacyCacheMigration.run(videosRoot: videos, legacyStreamRoot: nil, now: Date()).isEmpty)
        #expect(MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: videos)).count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LegacyCacheMigrationTests`
Expected: compile failure, `cannot find 'LegacyCacheMigration' in scope`.

- [ ] **Step 3: Implement**

`Sources/PatataTubeKit/LegacyCacheMigration.swift`:

```swift
import Foundation

/// 2.8 → 2.9: the stream cache, segmented part files and `.resume` files
/// are gone; paused downloads become paused, pinned store entries that
/// start from zero bytes once. Idempotent and cheap, so it runs on every
/// launch from `CacheManager.init`, before `MediaStore` touches the disk.
enum LegacyCacheMigration {
    /// Returns the keys turned into paused entries.
    @discardableResult
    static func run(videosRoot: URL, legacyStreamRoot: URL?, now: Date) -> [String] {
        let fm = FileManager.default
        if let legacyStreamRoot, fm.fileExists(atPath: legacyStreamRoot.path) {
            try? fm.removeItem(at: legacyStreamRoot)
            DevLog.event(.cache, "legacy stream cache removed", [:])
        }
        try? fm.removeItem(at: videosRoot.appendingPathComponent(".downloads", isDirectory: true))
        let contents = (try? fm.contentsOfDirectory(atPath: videosRoot.path)) ?? []
        for name in contents where name.hasSuffix(".resume") {
            try? fm.removeItem(at: videosRoot.appendingPathComponent(name))
        }

        // Loading the store drops 2.8 HLS entries and records their ids for
        // CacheManager.removeLegacyHLSPackages, exactly as before.
        var legacy = PausedDownloadStore(root: videosRoot)
        guard !legacy.entries.isEmpty else { return [] }
        let storeRoot = MediaStore.storeRoot(videosRoot: videosRoot)
        var converted: [String] = []
        for paused in legacy.entries {
            let key = paused.id
            let finished = videosRoot.appendingPathComponent(MediaKey.finishedFilename(key))
            guard !fm.fileExists(atPath: finished.path),
                  MediaStore.readManifest(storeRoot: storeRoot, key: key) == nil
            else { continue }
            let manifest = MediaEntryManifest(
                key: key,
                identity: nil,
                committed: ByteRangeSet(),
                pin: PinState(
                    job: DownloadJobParameters(
                        remoteURL: paused.remoteURL,
                        streamCount: paused.streamCount,
                        previewURL: paused.previewURL,
                        showPosterKey: paused.showPosterKey,
                        showPosterURL: paused.showPosterURL
                    ),
                    paused: true
                ),
                lastAccess: now
            )
            guard (try? MediaStore.writeManifest(manifest, storeRoot: storeRoot)) != nil else { continue }
            converted.append(key)
        }
        legacy.removeAll()
        DevLog.event(.download, "legacy paused downloads carried over", [
            "keys": converted.joined(separator: ","),
        ])
        return converted
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LegacyCacheMigrationTests`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/LegacyCacheMigration.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/LegacyCacheMigrationTests.swift
git commit -m "kit: migrate 2.8 caches into the media store on launch

Deletes Caches/stream, segmented part files and .resume files; each
paused download becomes a paused pinned entry that restarts from zero
once.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: DataTaskStream and ReadAheadLimiter

**Files:**
- Create: `Sources/PatataTubeKit/DataTaskStream.swift`
- Create: `Sources/PatataTubeKit/ReadAheadLimiter.swift`
- Modify: `Tests/PatataTubeKitTests/ChunkedRangeProtocol.swift` (record stopped ranges and delivered bytes)
- Test: `Tests/PatataTubeKitTests/DataTaskStreamTests.swift`

- [ ] **Step 1: Extend ChunkedRangeProtocol**

In `ChunkedRangeProtocol.swift`:

1. Next to `rangesByPath`, add:

```swift
    nonisolated(unsafe) private static var stoppedByPath: [String: [String]] = [:]
    nonisolated(unsafe) private static var deliveredByPath: [String: Int] = [:]
```

2. In `stub(path:plan:)` and `reset(path:)`, also reset them (`stoppedByPath[path] = []` / `nil`, and `deliveredByPath[path] = 0` / `nil`).

3. Add the accessors:

```swift
    /// Range headers whose response the client cancelled before it ended.
    static func stoppedRanges(path: String) -> [String] {
        lock.withLock { stoppedByPath[path] ?? [] }
    }

    /// Body bytes handed to clients for `path`, probes (`bytes=0-0`) excluded.
    static func deliveredByteCount(path: String) -> Int {
        lock.withLock { deliveredByPath[path] ?? 0 }
    }
```

4. In `startLoading()`'s chunk loop, replace the first `if cancelLock.withLock({ isCancelled }) { return }` with:

```swift
            if cancelLock.withLock({ isCancelled }) {
                Self.lock.withLock { Self.stoppedByPath[path, default: []].append(header) }
                return
            }
```

and right after `client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))` add:

```swift
            if header != "bytes=0-0" {
                Self.lock.withLock { Self.deliveredByPath[path, default: 0] += end - offset }
            }
```

(this line must come before `offset = end`).

- [ ] **Step 2: Write the failing tests**

`Tests/PatataTubeKitTests/DataTaskStreamTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Data task stream and read-ahead limiter")
struct DataTaskStreamTests {
    private let session = URLSession(configuration: ChunkedRangeProtocol.configuration())

    private func request(_ path: String, range: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://srv.test\(path)")!)
        request.setValue(range, forHTTPHeaderField: "Range")
        return request
    }

    @Test func deliversEveryChunkInOrderThenEnds() async throws {
        let path = "/dts/order"
        let body = sampleBody(1000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"o\"", chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (response, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-999"), session: session)
        #expect(response.statusCode == 206)
        var received = Data()
        for try await chunk in stream { received.append(chunk) }
        #expect(received == body)
    }

    @Test func surfacesAFailureAfterTheBytesThatArrived() async throws {
        let path = "/dts/fail"
        let body = sampleBody(1000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"f\"", chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: { $0 < 300 }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (_, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-999"), session: session)
        var received = Data()
        await #expect(throws: URLError.self) {
            for try await chunk in stream { received.append(chunk) }
        }
        #expect(received == body.prefix(300))
    }

    @Test func cancellingStopsTheTransfer() async throws {
        let path = "/dts/cancel"
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: sampleBody(100_000), etag: "\"c\"", chunkSize: 1000,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.005); return true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (_, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-99999"), session: session)
        _ = try await stream.nextChunk()
        stream.cancel()
        #expect(await eventually { ChunkedRangeProtocol.stoppedRanges(path: path) == ["bytes=0-99999"] })
    }

    @Test func limiterParksUntilTheReaderAdvances() async throws {
        let limiter = ReadAheadLimiter(lead: 100, position: 0)
        #expect(limiter.wouldWait(nextByte: 101))
        #expect(!limiter.wouldWait(nextByte: 100))
        let parked = Task { try await limiter.waitForRoom(nextByte: 300); return true }
        try await Task.sleep(for: .milliseconds(20))
        limiter.advance(to: 150)
        try await Task.sleep(for: .milliseconds(20))
        limiter.advance(to: 200)
        #expect(try await parked.value)
    }

    @Test func cancellingTheLimiterReleasesWaiters() async throws {
        let limiter = ReadAheadLimiter(lead: 0, position: 0)
        let parked = Task { try await limiter.waitForRoom(nextByte: 10) }
        try await Task.sleep(for: .milliseconds(20))
        limiter.cancel()
        await #expect(throws: CancellationError.self) { try await parked.value }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DataTaskStreamTests`
Expected: compile failure, `cannot find 'DataTaskStream' in scope`.

- [ ] **Step 4: Implement**

`Sources/PatataTubeKit/DataTaskStream.swift`:

```swift
import Foundation

/// One URLSession data task read as an async sequence of chunks.
///
/// Flow control is real. Past `highWater` unread bytes the task is
/// suspended, and it resumes once the reader drains below `lowWater`, so a
/// parked playback fetcher stops pulling from the network instead of filling
/// memory. Uses a per-task delegate, so it works on any session.
final class DataTaskStream: NSObject, URLSessionDataDelegate, AsyncSequence, @unchecked Sendable {
    typealias Element = Data

    static let highWater = 4 * 1_048_576
    static let lowWater = 1_048_576

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var chunks: [Data] = []
    private var bufferedByteCount = 0
    private var isFinished = false
    private var isCancelled = false
    private var failure: Error?
    private var dataWaiter: CheckedContinuation<Void, Never>?
    private var isSuspended = false

    /// Starts `request` and returns once the response headers arrive.
    static func start(_ request: URLRequest, session: URLSession) async throws -> (HTTPURLResponse, DataTaskStream) {
        let stream = DataTaskStream()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.dataTask(with: request)
                task.delegate = stream
                let cancelledAlready = stream.lock.withLock { () -> Bool in
                    stream.task = task
                    if stream.isCancelled { return true }
                    stream.responseContinuation = continuation
                    return false
                }
                if cancelledAlready {
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            stream.cancel()
        }
        return (response, stream)
    }

    /// Stops the transfer and wakes a waiting reader. Safe to call twice.
    func cancel() {
        let (task, waiter) = lock.withLock { () -> (URLSessionDataTask?, CheckedContinuation<Void, Never>?) in
            isCancelled = true
            defer { dataWaiter = nil }
            return (self.task, dataWaiter)
        }
        task?.cancel()
        waiter?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        let continuation = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { responseContinuation = nil }
            return responseContinuation
        }
        if let http = response as? HTTPURLResponse {
            continuation?.resume(returning: http)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (waiter, suspend) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
            chunks.append(data)
            bufferedByteCount += data.count
            let waiter = dataWaiter
            dataWaiter = nil
            let suspend = !isSuspended && bufferedByteCount >= Self.highWater
            if suspend { isSuspended = true }
            return (waiter, suspend)
        }
        if suspend { dataTask.suspend() }
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, waiter) = lock.withLock {
            () -> (CheckedContinuation<HTTPURLResponse, Error>?, CheckedContinuation<Void, Never>?) in
            isFinished = true
            failure = error
            defer {
                responseContinuation = nil
                dataWaiter = nil
            }
            return (responseContinuation, dataWaiter)
        }
        continuation?.resume(throwing: error ?? URLError(.badServerResponse))
        waiter?.resume()
    }

    // MARK: Reading

    struct Iterator: AsyncIteratorProtocol {
        let stream: DataTaskStream
        mutating func next() async throws -> Data? {
            try await stream.nextChunk()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(stream: self)
    }

    private enum Step {
        case chunk(Data, resume: URLSessionDataTask?)
        case end
        case fail(Error)
        case wait
    }

    /// The next chunk, nil at the end of the body. Bytes that arrived before
    /// a failure are all returned before the failure is thrown.
    func nextChunk() async throws -> Data? {
        while true {
            if Task.isCancelled {
                cancel()
                throw CancellationError()
            }
            let step = lock.withLock { () -> Step in
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    bufferedByteCount -= chunk.count
                    var resume: URLSessionDataTask?
                    if isSuspended, bufferedByteCount <= Self.lowWater {
                        isSuspended = false
                        resume = task
                    }
                    return .chunk(chunk, resume: resume)
                }
                if isCancelled { return .fail(CancellationError()) }
                if isFinished { return failure.map(Step.fail) ?? .end }
                return .wait
            }
            switch step {
            case .chunk(let chunk, let resume):
                resume?.resume()
                return chunk
            case .end:
                return nil
            case .fail(let error):
                throw error
            case .wait:
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let ready = lock.withLock { () -> Bool in
                            if !chunks.isEmpty || isFinished || isCancelled { return true }
                            dataWaiter = continuation
                            return false
                        }
                        if ready { continuation.resume() }
                    }
                } onCancel: {
                    self.cancel()
                }
            }
        }
    }
}
```

`Sources/PatataTubeKit/ReadAheadLimiter.swift`:

```swift
import Foundation

/// Keeps a playback fetcher at most `lead` bytes ahead of what its reader has
/// sent. AVPlayer asks for the whole file and reads slowly; without this,
/// every tapped video would download completely.
final class ReadAheadLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let lead: Int64
    private var position: Int64
    private var isCancelled = false
    private var waiters: [UUID: (nextByte: Int64, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(lead: Int64, position: Int64) {
        self.lead = lead
        self.position = position
    }

    func wouldWait(nextByte: Int64) -> Bool {
        lock.withLock { nextByte - position > lead }
    }

    /// The reader has sent everything before `newPosition`.
    func advance(to newPosition: Int64) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            position = max(position, newPosition)
            let ids = waiters.filter { $0.value.nextByte - position <= lead }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once fetching `nextByte` keeps within the lead. Throws
    /// `CancellationError` when cancelled or when the limiter is.
    func waitForRoom(nextByte: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let verdict = lock.withLock { () -> Result<Void, Error>? in
                    if isCancelled || Task.isCancelled { return .failure(CancellationError()) }
                    if nextByte - position <= lead { return .success(()) }
                    waiters[id] = (nextByte, continuation)
                    return nil
                }
                if let verdict { continuation.resume(with: verdict) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func cancel() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isCancelled = true
            defer { waiters.removeAll() }
            return waiters.values.map(\.continuation)
        }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DataTaskStreamTests`
Expected: all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DataTaskStream.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/ReadAheadLimiter.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/ChunkedRangeProtocol.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DataTaskStreamTests.swift
git commit -m "kit: streamed data tasks with flow control, read-ahead limiter

DataTaskStream suspends its task past 4 MB unread, so a parked playback
fetcher stops pulling bytes; ReadAheadLimiter parks it 32 MB ahead of
its reader.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Upstream requests, identity probe, RangeFetcher

**Files:**
- Create: `Sources/PatataTubeKit/UpstreamRequests.swift`
- Create: `Sources/PatataTubeKit/IdentityProbe.swift`
- Create: `Sources/PatataTubeKit/RangeFetcher.swift`
- Test: `Tests/PatataTubeKitTests/RangeFetcherTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PatataTubeKitTests/RangeFetcherTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

/// Thread-safe one-shot flag for URL-protocol callbacks.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True the first time only.
    func setOnce() -> Bool { lock.withLock { defer { set = true }; return !set } }
}

@Suite("Range fetcher")
struct RangeFetcherTests {
    private let body = sampleBody(1000)
    private let identity = MediaIdentity(etag: "\"r\"", totalByteCount: 1000)
    private let session = URLSession(configuration: ChunkedRangeProtocol.configuration())

    private func fetcher(
        _ store: MediaStore, key: String, path: String, generation: Int,
        identity: MediaIdentity? = nil, commitSize: Int = 100, maxAttempts: Int = 4,
        limiter: ReadAheadLimiter? = nil
    ) -> RangeFetcher {
        RangeFetcher(
            store: store, key: key, identity: identity ?? self.identity, generation: generation,
            session: session,
            upstream: UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil, fallbackToken: "tok"),
            commitSize: commitSize, maxAttempts: maxAttempts, limiter: limiter
        )
    }

    private func stub(_ path: String, etag: String = "\"r\"", afterChunk: @escaping (Int) -> Bool = { _ in true }) {
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: etag, chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: afterChunk
        ))
    }

    @Test func commitsEachChunkBeforeTheBodyEnds() async throws {
        let path = "/rf/commit"
        let release = DispatchSemaphore(value: 0)
        stub(path) { delivered in
            if delivered == 500 { _ = release.wait(timeout: .now() + 5) }
            return true
        }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        let run = Task { try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) }
        #expect(await eventually { await store.available(key: "1", from: 0)?.bytes == 500 })
        release.signal()
        #expect(try await run.value == .promoted)
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
        let request = try #require(ChunkedRangeProtocol.recordedRanges(path: path).first)
        #expect(request == "bytes=0-999")
    }

    @Test func stopsAtBytesAlreadyStored() async throws {
        let path = "/rf/stop"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 600, end: 999), generation: generation, from: body)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        #expect(try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) == .promoted)
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-599"])
    }

    @Test func parksAtTheReadAheadLeadAndMarksItsClaimIdle() async throws {
        let path = "/rf/lead"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0)
        else { Issue.record("refused"); return }
        let limiter = ReadAheadLimiter(lead: 200, position: 0)
        let run = Task { try await fetcher(store, key: "1", path: path, generation: generation, limiter: limiter).run(claim: claim.id) }
        #expect(await eventually { await store.claimSnapshot(key: "1", id: claim.id)?.idle == true })
        let parkedAt = await store.available(key: "1", from: 0)?.bytes ?? -1
        #expect(parkedAt >= 200 && parkedAt <= 300)
        limiter.advance(to: 1000)
        #expect(try await run.value == .promoted)
    }

    @Test func retriesFromItsLastCommit() async throws {
        let path = "/rf/retry"
        let failed = Flag()
        stub(path) { delivered in !(delivered == 400 && failed.setOnce()) }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        #expect(try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id) == .promoted)
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-999", "bytes=400-999"])
    }

    @Test func reportsAChangedFileWithItsNewIdentity() async throws {
        let path = "/rf/etag"
        stub(path, etag: "\"other\"")
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        guard case .granted(let claim) = await store.claim(key: "1", from: 0, through: 999, owner: .download, waitWithin: 0)
        else { Issue.record("refused"); return }
        await #expect(throws: RangeFetchError.entityChanged(MediaIdentity(etag: "\"other\"", totalByteCount: 1000))) {
            _ = try await fetcher(store, key: "1", path: path, generation: generation).run(claim: claim.id)
        }
    }

    @Test func requestsFollowTheCurrentBaseURLAndToken() async throws {
        let path = "/rf/headers"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let request = UpstreamRequests(
            url: URL(string: "https://remote.test\(path)?version_id=2")!,
            credentials: InMemoryCredentialStore(baseURL: URL(string: "http://192.168.1.1:3050"), token: "live"),
            fallbackToken: "stale"
        ).ranged(DownloadByteRange(start: 5, end: 9))
        #expect(request.url?.absoluteString == "http://192.168.1.1:3050\(path)?version_id=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=5-9")
    }

    @Test func probeReadsTheIdentity() async throws {
        let path = "/rf/probe"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let upstream = UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil)
        #expect(try await IdentityProbe.fetch(upstream.probe(), session: session) == identity)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RangeFetcherTests`
Expected: compile failure, `cannot find 'RangeFetcher' in scope`.

- [ ] **Step 3: Implement**

`Sources/PatataTubeKit/UpstreamRequests.swift`:

```swift
import Foundation

/// Builds upstream requests from the credentials as they are **now**, so a
/// retry follows a LAN↔remote route switch and a refreshed token.
///
/// `@unchecked Sendable`: `CredentialStore` is a non-Sendable class protocol
/// that the old proxy also read from background threads; reads only.
struct UpstreamRequests: @unchecked Sendable {
    /// The URL as the caller built it.
    let url: URL
    /// When set, every request moves `url` onto this store's current base URL
    /// and uses its current token.
    let credentials: CredentialStore?
    let fallbackToken: String?

    init(url: URL, credentials: CredentialStore?, fallbackToken: String? = nil) {
        self.url = url
        self.credentials = credentials
        self.fallbackToken = fallbackToken
    }

    func ranged(_ range: DownloadByteRange) -> URLRequest {
        var request = URLRequest(url: currentURL())
        if let token = credentials?.token ?? fallbackToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        return request
    }

    func probe() -> URLRequest {
        ranged(DownloadByteRange(start: 0, end: 0))
    }

    func currentURL() -> URL {
        guard let base = credentials?.baseURL else { return url }
        return Self.rebase(url, onto: base)
    }

    /// Swaps scheme, host and port. Assumes both bases share their path
    /// prefix, which holds for the LAN and remote URLs (both are bare hosts).
    static func rebase(_ url: URL, onto base: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = target.scheme
        components.host = target.host
        components.port = target.port
        return components.url ?? url
    }
}
```

`Sources/PatataTubeKit/IdentityProbe.swift`:

```swift
import Foundation

enum IdentityProbeError: Error, Equatable {
    /// Not a `bytes=0-0` 206 with a strong ETag: the server ignores ranges.
    case invalid
}

/// Learns a remote file's identity with one `bytes=0-0` request.
enum IdentityProbe {
    static func fetch(_ request: URLRequest, session: URLSession) async throws -> MediaIdentity {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IdentityProbeError.invalid }
        if (400..<600).contains(http.statusCode) { throw APIError.badStatus(http.statusCode) }
        return try identity(from: http, bodyCount: body.count)
    }

    static func identity(from response: HTTPURLResponse, bodyCount: Int) throws -> MediaIdentity {
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              bodyCount == 1,
              let etag = response.value(forHTTPHeaderField: "ETag"),
              isValidStrongETag(etag),
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0
        else { throw IdentityProbeError.invalid }
        return MediaIdentity(etag: etag, totalByteCount: total)
    }
}

private func isValidStrongETag(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return false }
    return bytes.dropFirst().dropLast().allSatisfy {
        $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80
    }
}
```

`Sources/PatataTubeKit/RangeFetcher.swift`:

```swift
import Foundation

enum RangeFetchError: Error, Equatable {
    /// The server now has a different file. Carries the new identity when the
    /// response named one (a 200 to an `If-Range` request names none).
    case entityChanged(MediaIdentity?)
    case invalidResponse
    /// The body ended before the requested range did.
    case shortBody
}

enum FetchOutcome: Equatable, Sendable {
    case finished
    case promoted
    case stale
}

struct ContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ value: String) {
        guard value.hasPrefix("bytes "),
              let slash = value.firstIndex(of: "/"),
              let total = Int64(value[value.index(after: slash)...]),
              total > 0
        else { return nil }
        let bounds = value[value.index(value.startIndex, offsetBy: 6)..<slash]
            .split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total
        else { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}

/// Fetches one claim from upstream into the store: one `Range` request from
/// the claim's cursor to its end, writing each piece to `data.bin` and
/// committing it every `commitSize` bytes. The claim may be shortened while
/// it runs (a reader or a download took over the rest); the fetcher learns
/// that from each commit and stops. A transient failure retries from the
/// last commit, up to `maxAttempts` attempts in all. **The caller releases
/// the claim** when `run` returns.
///
/// A write past a shortened end can happen for at most one commit. It is
/// byte-identical (same identity) and never committed, so it is harmless.
struct RangeFetcher: Sendable {
    static let defaultCommitSize = 256 * 1024

    let store: MediaStore
    let key: String
    let identity: MediaIdentity
    let generation: Int
    let session: URLSession
    let upstream: UpstreamRequests
    var commitSize = RangeFetcher.defaultCommitSize
    var maxAttempts = 4
    var limiter: ReadAheadLimiter?

    func run(claim id: ClaimID) async throws -> FetchOutcome {
        var failures = 0
        while true {
            try Task.checkCancellation()
            guard let claim = await store.claimSnapshot(key: key, id: id) else { return .finished }
            do {
                return try await fetch(claim)
            } catch let error where Self.isTransient(error) && failures + 1 < maxAttempts {
                failures += 1
                DevLog.event(.cache, "range fetch retry", [
                    "key": key, "attempt": "\(failures + 1)", "err": "\(error)",
                ])
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case .badStatus(let status)? = error as? APIError { return (500..<600).contains(status) }
        return error as? RangeFetchError == .shortBody
    }

    static func validate(_ response: HTTPURLResponse, identity: MediaIdentity?, start: Int64) throws {
        switch response.statusCode {
        case 206:
            break
        case 200:
            // An If-Range miss: the server sent the whole, different file.
            throw RangeFetchError.entityChanged(nil)
        case 400..<600:
            throw APIError.badStatus(response.statusCode)
        default:
            throw RangeFetchError.invalidResponse
        }
        guard let range = response.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init) else {
            throw RangeFetchError.invalidResponse
        }
        let etag = response.value(forHTTPHeaderField: "ETag")
        if let identity, etag != identity.etag || range.total != identity.totalByteCount {
            throw RangeFetchError.entityChanged(etag.map { MediaIdentity(etag: $0, totalByteCount: range.total) })
        }
        guard range.start == start else { throw RangeFetchError.invalidResponse }
    }

    private func fetch(_ claim: ClaimSnapshot) async throws -> FetchOutcome {
        var offset = claim.cursor
        var end = claim.end
        guard offset <= end else { return .finished }
        var request = upstream.ranged(DownloadByteRange(start: offset, end: end))
        request.setValue(identity.etag, forHTTPHeaderField: "If-Range")
        let (response, body) = try await DataTaskStream.start(request, session: session)
        defer { body.cancel() }
        try Self.validate(response, identity: identity, start: offset)
        guard let handle = try? FileHandle(forWritingTo: store.dataURL(key: key)) else { return .stale }
        defer { try? handle.close() }

        var pending = Data()
        for try await chunk in body {
            pending.append(chunk)
            guard pending.count >= commitSize else { continue }
            if let outcome = try await commit(&pending, claim: claim.id, offset: &offset, end: &end, handle: handle) {
                return outcome
            }
        }
        if !pending.isEmpty,
           let outcome = try await commit(&pending, claim: claim.id, offset: &offset, end: &end, handle: handle) {
            return outcome
        }
        guard offset > end else { throw RangeFetchError.shortBody }
        return .finished
    }

    /// Writes and commits everything pending, clipped to the claim's end.
    /// Returns an outcome when this fetch is over.
    private func commit(
        _ pending: inout Data,
        claim id: ClaimID,
        offset: inout Int64,
        end: inout Int64,
        handle: FileHandle
    ) async throws -> FetchOutcome? {
        let length = Int(min(Int64(pending.count), end - offset + 1))
        let piece = pending.prefix(length)
        pending = Data()
        try await write(piece, at: offset, handle: handle)
        let result = try await store.commit(
            key: key, claim: id, generation: generation, through: offset + Int64(length) - 1
        )
        offset += Int64(length)
        switch result {
        case .continueThrough(let newEnd):
            end = newEnd
            if offset > end { return .finished }
        case .finished:
            return .finished
        case .promoted:
            return .promoted
        case .stale:
            return .stale
        }
        if let limiter, limiter.wouldWait(nextByte: offset) {
            await store.setClaimIdle(key: key, id: id, idle: true)
            do {
                try await limiter.waitForRoom(nextByte: offset)
            } catch {
                await store.setClaimIdle(key: key, id: id, idle: false)
                throw error
            }
            await store.setClaimIdle(key: key, id: id, idle: false)
        }
        return nil
    }

    /// A failed write evicts one idle unpinned entry and retries once.
    private func write(_ piece: Data, at offset: Int64, handle: FileHandle) async throws {
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: piece)
        } catch {
            DevLog.event(.cache, "store write failed, evicting and retrying", [
                "key": key, "offset": "\(offset)", "bytes": "\(piece.count)", "err": "\(error)",
            ])
            guard await store.evictForStorageFailure(excluding: key) else {
                throw MediaStoreError.storageFull
            }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: piece)
            } catch {
                throw MediaStoreError.storageFull
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RangeFetcherTests`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/UpstreamRequests.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/IdentityProbe.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherTests.swift
git commit -m "kit: RangeFetcher streams one claim into the store

Commits every 256 KB, stops where someone else's bytes begin, parks at
the read-ahead lead with its claim marked idle, and retries from its
last commit against the current base URL.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: DownloadJobRunner

**Files:**
- Create: `Sources/PatataTubeKit/DownloadJobRunner.swift`
- Test: `Tests/PatataTubeKitTests/DownloadJobRunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PatataTubeKitTests/DownloadJobRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download job runner")
struct DownloadJobRunnerTests {
    private let body = sampleBody(1000)
    private let identity = MediaIdentity(etag: "\"j\"", totalByteCount: 1000)

    private func runner(
        _ store: MediaStore, key: String, path: String, streams: Int,
        minPiece: Int64 = 1, commitSize: Int = 50, maxAttempts: Int = 4
    ) -> DownloadJobRunner {
        DownloadJobRunner(
            store: store, key: key, streamCount: streams,
            session: URLSession(configuration: ChunkedRangeProtocol.configuration()),
            upstream: UpstreamRequests(url: URL(string: "https://srv.test\(path)")!, credentials: nil),
            tuning: DownloadTuning(minPiece: minPiece, commitSize: commitSize, maxAttempts: maxAttempts),
            onProgress: { _ in }
        )
    }

    private func stub(_ path: String, etag: String = "\"j\"", afterChunk: @escaping (Int) -> Bool = { _ in true }) {
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: etag, chunkSize: 50,
            failureError: URLError(.networkConnectionLost), afterChunk: afterChunk
        ))
    }

    @Test func fourStreamsFillAndPromoteTheFile() async throws {
        let path = "/job/four"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        try await runner(store, key: "1", path: path, streams: 4).run()
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
        let ranges = ChunkedRangeProtocol.recordedRanges(path: path)
        #expect(ranges.first == "bytes=0-0")
        #expect(Set(ranges.dropFirst().prefix(4)) == [
            "bytes=0-249", "bytes=250-499", "bytes=500-749", "bytes=750-999",
        ])
    }

    @Test func fetchesOnlyTheHoles() async throws {
        let path = "/job/holes"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        let generation = try await store.open(key: "1", identity: identity)
        try await put(store, key: "1", DownloadByteRange(start: 0, end: 499), generation: generation, from: body)
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=500-999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func takesOverAParkedPlaybackClaim() async throws {
        let path = "/job/idle"
        stub(path)
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        guard case .granted(let parked) = await store.claim(key: "1", from: 0, through: 999, owner: .playback, waitWithin: 0)
        else { Issue.record("refused"); return }
        await store.setClaimIdle(key: "1", id: parked.id, idle: true)
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func restartsWhenTheFileChangedOnTheServer() async throws {
        let path = "/job/changed"
        stub(path, etag: "\"new\"")
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: MediaIdentity(etag: "\"old\"", totalByteCount: 1000))
        try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000).run()
        #expect(ChunkedRangeProtocol.recordedRanges(path: path) == ["bytes=0-999", "bytes=0-999"])
        #expect(try Data(contentsOf: store.finishedURL(key: "1")) == body)
    }

    @Test func failsAfterTheRetriesRunOutAndKeepsTheEntry() async throws {
        let path = "/job/fail"
        stub(path) { _ in false }
        defer { ChunkedRangeProtocol.reset(path: path) }
        let store = MediaStore(videosRoot: temporaryVideosRoot())
        _ = try await store.open(key: "1", identity: identity)
        await #expect(throws: URLError.self) {
            try await runner(store, key: "1", path: path, streams: 1, minPiece: 10_000, commitSize: 1000).run()
        }
        #expect(ChunkedRangeProtocol.recordedRanges(path: path).count == 4)
        #expect(await store.manifest(key: "1") != nil)
        #expect(await store.claims(key: "1").isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadJobRunnerTests`
Expected: compile failure, `cannot find 'DownloadJobRunner' in scope`.

- [ ] **Step 3: Implement**

`Sources/PatataTubeKit/DownloadJobRunner.swift`:

```swift
import Foundation

struct DownloadTuning: Sendable {
    /// Never split a remainder into pieces smaller than this.
    var minPiece: Int64 = 4 * 1_048_576
    var commitSize = RangeFetcher.defaultCommitSize
    /// 1 + 3 retries in place, per the spec.
    var maxAttempts = 4
}

/// One download's transfer. Probes the identity once per process, then keeps
/// up to `streamCount` fetchers on the entry's holes until the file is
/// promoted. Holes may close under it (someone is watching), and a playback
/// claim's remainder opens up again when that reader goes away; every store
/// change wakes the loop to re-plan.
struct DownloadJobRunner: Sendable {
    static let maxIdentityResets = 2

    let store: MediaStore
    let key: String
    let streamCount: Int
    let session: URLSession
    let upstream: UpstreamRequests
    let tuning: DownloadTuning
    let onProgress: @Sendable (MediaEntryManifest) -> Void

    private enum Event: Sendable {
        case fetcherEnded(Result<FetchOutcome, Error>)
        case storeChanged
    }

    func run() async throws {
        var resets = 0
        while true {
            try Task.checkCancellation()
            if try await store.promoteIfComplete(key: key) { return }
            let (identity, generation) = try await resolveIdentity()
            do {
                try await fill(identity: identity, generation: generation)
                return
            } catch RangeFetchError.entityChanged(let newIdentity) {
                resets += 1
                guard resets <= Self.maxIdentityResets else {
                    throw RangeFetchError.entityChanged(newIdentity)
                }
                DevLog.event(.download, "download restarting: file changed on the server", ["key": key])
                if let newIdentity {
                    _ = try await store.open(key: key, identity: newIdentity)
                } else {
                    await store.invalidate(key: key)
                }
            }
        }
    }

    private func resolveIdentity() async throws -> (MediaIdentity, Int) {
        if let known = await store.verifiedIdentity(key: key) {
            return (known.identity, known.generation)
        }
        let identity = try await IdentityProbe.fetch(upstream.probe(), session: session)
        do {
            return (identity, try await store.open(key: key, identity: identity))
        } catch {
            guard await store.evictForStorageFailure(excluding: key) else { throw error }
            return (identity, try await store.open(key: key, identity: identity))
        }
    }

    private func fill(identity: MediaIdentity, generation: Int) async throws {
        try await withThrowingTaskGroup(of: Event.self) { group in
            defer { group.cancelAll() }
            var running = 0
            var watching = false
            while true {
                if try await store.promoteIfComplete(key: key) { return }
                let seen = await store.version(key: key)
                if let manifest = await store.manifest(key: key) { onProgress(manifest) }
                let claims = await store.claimForDownload(
                    key: key, slots: streamCount - running, minPiece: tuning.minPiece
                )
                for claim in claims {
                    running += 1
                    let fetcher = RangeFetcher(
                        store: store, key: key, identity: identity, generation: generation,
                        session: session, upstream: upstream,
                        commitSize: tuning.commitSize, maxAttempts: tuning.maxAttempts
                    )
                    let store = store
                    let key = key
                    group.addTask {
                        let result: Result<FetchOutcome, Error>
                        do {
                            result = .success(try await fetcher.run(claim: claim.id))
                        } catch {
                            result = .failure(error)
                        }
                        await store.releaseClaim(key: key, id: claim.id)
                        return .fetcherEnded(result)
                    }
                }
                if !watching {
                    watching = true
                    let store = store
                    let key = key
                    group.addTask {
                        await store.waitForChange(key: key, after: seen)
                        return .storeChanged
                    }
                }
                guard let event = try await group.next() else { continue }
                switch event {
                case .storeChanged:
                    watching = false
                case .fetcherEnded(let result):
                    running -= 1
                    switch result {
                    case .success(.promoted):
                        return
                    case .success(.stale):
                        // Reset or deleted under us: re-resolve and start over.
                        throw RangeFetchError.entityChanged(nil)
                    case .success(.finished):
                        break
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadJobRunnerTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadJobRunner.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadJobRunnerTests.swift
git commit -m "kit: DownloadJobRunner fills a store entry's holes

Keeps streamCount fetchers on the holes, re-plans on every store change,
takes over a parked playback claim, and restarts once if the file
changed on the server.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Rewrite CacheManager onto the store

**Files:**
- Rewrite: `Sources/PatataTubeKit/CacheManager.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift` (one line)
- Rewrite: `Tests/PatataTubeKitTests/CacheManagerTests.swift`
- Rewrite: `Tests/PatataTubeKitTests/CacheManagerPauseTests.swift`
- Delete: `Tests/PatataTubeKitTests/CacheManagerSegmentSinkTests.swift`, `Tests/PatataTubeKitTests/StreamCacheSeedTests.swift`

The public API (`state`, `activeDownloads`, `download`, `pause`, `resume`, `cancel`, `resumeInterrupted`, `removeCached`, `removeAllCached`, `clearAllVideos`, previews, posters, the gate) keeps its signatures. Two exceptions: the convenience init drops `streamCache:` and gains `credentials:`, and `mediaStore` and `settleStoreWork()` are new.

- [ ] **Step 1: Rewrite the pause tests (failing)**

Replace the whole of `Tests/PatataTubeKitTests/CacheManagerPauseTests.swift` with:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

/// Grants at once and counts, so a test can see a permit held or returned.
private final class RecordingGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private var acquires = 0
    private var releases = 0
    func acquire() async { lock.withLock { acquires += 1 } }
    func release() { lock.withLock { releases += 1 } }
    func setLimit(_ n: Int) {}
    var currentLimit: Int { 3 }
    var counts: (acquires: Int, releases: Int) { lock.withLock { (acquires, releases) } }
}

@Suite("Cache manager pause, resume and cancel")
struct CacheManagerPauseTests {
    private func manager(root: URL, gate: any DownloadConcurrencyGating = DownloadConcurrencyGate(limit: 3)) -> CacheManager {
        CacheManager(
            root: root, configuration: ChunkedRangeProtocol.configuration(), fileManager: .default,
            concurrencyGate: gate, fetchTuning: DownloadTuning(minPiece: 1_048_576, commitSize: 64)
        )
    }

    private func pinnedManifest(key: String, path: String, paused: Bool,
                                identity: MediaIdentity? = nil, committed: ByteRangeSet = ByteRangeSet()) -> MediaEntryManifest {
        MediaEntryManifest(
            key: key, identity: identity, committed: committed,
            pin: PinState(job: DownloadJobParameters(
                remoteURL: URL(string: "https://srv.test\(path)")!, streamCount: 1,
                previewURL: nil, showPosterKey: nil, showPosterURL: nil
            ), paused: paused),
            lastAccess: Date()
        )
    }

    @Test func pausingKeepsTheBytesAndResumeFetchesOnlyTheRest() async throws {
        let root = temporaryVideosRoot("pause")
        let path = "/videos/81/stream"
        let payload = sampleBody(4096)
        let manager = manager(root: root)
        let paused = Flag()
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: payload, etag: "\"p81\"", chunkSize: 64,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { delivered in
                if delivered >= 1024, paused.setOnce() {
                    manager.pause(id: 81, remote: URL(string: "https://srv.test\(path)")!, streamCount: 1)
                }
                return true
            }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }

        await #expect(throws: DownloadPausedError.self) {
            try await manager.download(id: 81, from: URL(string: "https://srv.test\(path)")!)
        }
        await manager.settleStoreWork()
        let manifest = try #require(await manager.mediaStore.manifest(key: "81"))
        #expect(manifest.pin?.paused == true)
        let kept = manifest.committed.totalBytes
        #expect(kept >= 64 && kept < 4096)
        #expect(manager.activeDownloads().map(\.isPaused) == [true])
        if case .downloading = manager.state(for: 81) {} else {
            Issue.record("a paused download should read as downloading, got \(manager.state(for: 81))")
        }

        try await manager.resume(id: 81)

        #expect(try Data(contentsOf: manager.localURL(for: 81)) == payload)
        let ranges = ChunkedRangeProtocol.recordedRanges(path: path).filter { $0 != "bytes=0-0" }
        #expect(ranges == ["bytes=0-4095", "bytes=\(kept)-4095"])
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func aPausedDownloadReloadsAsPaused() throws {
        let root = temporaryVideosRoot("pause")
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 399))
        try MediaStore.writeManifest(
            pinnedManifest(key: "82", path: "/videos/82/stream", paused: true,
                           identity: MediaIdentity(etag: "\"e\"", totalByteCount: 1000), committed: committed),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let manager = manager(root: root)
        #expect(manager.activeDownloads() == [DownloadActivity(
            videoID: 82, versionID: nil, progress: 0.4, transferredByteCount: 400,
            totalByteCount: 1000, isPaused: true
        )])
        #expect(manager.state(for: 82) == .downloading(0.4))
    }

    @Test func aStoredPausedDownloadHoldsAPermitUntilCancelled() async throws {
        let root = temporaryVideosRoot("pause")
        try MediaStore.writeManifest(
            pinnedManifest(key: "83", path: "/videos/83/stream", paused: true),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let gate = RecordingGate()
        let manager = manager(root: root, gate: gate)
        #expect(await eventually { gate.counts.acquires == 1 })
        #expect(gate.counts.releases == 0)
        manager.cancel(id: 83)
        #expect(await eventually { gate.counts.releases == 1 })
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "83") == nil)
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func resumeInterruptedRestartsPinnedUnpausedDownloads() async throws {
        let root = temporaryVideosRoot("pause")
        let path = "/videos/84/stream"
        let payload = sampleBody(512)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: payload, etag: "\"p84\"", chunkSize: 64,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        try MediaStore.writeManifest(
            pinnedManifest(key: "84", path: path, paused: false),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        let manager = manager(root: root)
        #expect(manager.resumeInterrupted() == [84])
        #expect(await eventually { manager.state(for: 84) == .cached })
        #expect(try Data(contentsOf: manager.localURL(for: 84)) == payload)
    }

    @Test func resumeInterruptedLeavesPausedDownloadsAlone() throws {
        let root = temporaryVideosRoot("pause")
        try MediaStore.writeManifest(
            pinnedManifest(key: "86", path: "/videos/86/stream", paused: true),
            storeRoot: MediaStore.storeRoot(videosRoot: root)
        )
        #expect(manager(root: root).resumeInterrupted() == [])
    }

    @Test func cancellingWhileAPlayerReadsDefersTheDelete() async throws {
        let root = temporaryVideosRoot("pause")
        let manager = manager(root: root)
        let store = manager.mediaStore
        _ = try await store.open(key: "85", identity: MediaIdentity(etag: "\"e\"", totalByteCount: 100))
        await store.beginRead(key: "85")
        manager.cancel(id: 85)
        await manager.settleStoreWork()
        #expect(FileManager.default.fileExists(atPath: store.entryDir(key: "85").path))
        await store.endRead(key: "85")
        #expect(!FileManager.default.fileExists(atPath: store.entryDir(key: "85").path))
    }

    @Test func resumingAnUnknownKeyDoesNothing() async throws {
        let manager = manager(root: temporaryVideosRoot("pause"))
        try await manager.resume(id: 999)
        #expect(manager.state(for: 999) == .notCached)
    }
}
```

(`Flag`, `sampleBody`, `temporaryVideosRoot` and `eventually` come from Tasks 3 and 7.)

- [ ] **Step 2: Rewrite CacheManagerTests.swift (failing)**

Edit `Tests/PatataTubeKitTests/CacheManagerTests.swift` in place:

1. **Keep** these top-level declarations unchanged: `RangeDownloadProtocol`, `HangingRangeProtocol`, `SegmentBlipThenSucceedProtocol`, `rangeDownloadConfig()`, `hangingRangeConfig()`, `segmentBlipConfig()`, `tempRoot()`.
2. **Delete** every other top-level `private` class, actor, struct and function in the fixture region: `HangingDownloadProtocol`, `PausedLegacyResumeProtocol`, `ResumableFailureProtocol`, `FreshRangeHangingProtocol`, `TransportThenUnsafeFailureProtocol`, `SegmentFailureProtocol`, `CancelThenRetryDownloadProtocol`, `StalledProbeProtocol`, `OwnershipRaceProtocol`, `BlockingSegmentFileManager`, `TrackingCancellationFence`, `TestClock`, `BlockingStreamCacheSeeder`, and their `…Config()` functions.
3. **Replace** the whole `@Suite(.serialized) struct CacheManagerTests { … }` with the suite below. Inside it, paste unchanged the six poster tests from the old suite: `showPosterStoreAndLookup`, `showPosterStoreAndLookupUsesShowID`, `showPosterKeyIsStableAndExtSanitized`, `downloadAlsoCachesShowPoster`, `showPosterFailureStillCachesVideo` and `downloadSkipsPosterFetchWhenAlreadyCached`. They use only the public API.

```swift
@Suite(.serialized)
struct CacheManagerTests {
    private func splittingManager(root: URL, configuration: URLSessionConfiguration) -> CacheManager {
        CacheManager(root: root, configuration: configuration, fileManager: .default,
                     fetchTuning: DownloadTuning(minPiece: 1))
    }

    @Test func localURLUsesIdAndMp4() {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
        #expect(manager.localURL(for: 5, versionId: 2).lastPathComponent == "5.v2.mp4")
    }

    @Test func stateIsNotCachedThenCachedAfterDownload() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.state(for: 11) == .notCached)
        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01, 0x02, 0x03]))
        try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)
        #expect(manager.state(for: 11) == .cached)
        #expect(try Data(contentsOf: manager.localURL(for: 11)) == Data([0x00, 0x01, 0x02, 0x03]))
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "11") == nil, "promotion removes the entry")
        #expect(manager.recentDownloads().map(\.videoID) == [11])
    }

    @Test func downloadAlsoCachesPreview() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 12, path: "https://img.test/thumb.jpg") == nil)
        RangeDownloadProtocol.reset(payload: Data([0x00, 0x01]))
        try await manager.download(
            id: 12,
            from: URL(string: "https://srv.test/videos/12/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )
        let previewURL = try #require(manager.cachedPreviewURL(for: 12, path: "https://img.test/thumb.jpg"))
        #expect(previewURL.pathExtension == "jpg")
        #expect(try Data(contentsOf: previewURL) == Data([0xAA, 0xBB]))
    }

    @Test func previewStoreAndLookupUsesMovieID() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        #expect(manager.cachedPreviewURL(for: 44, path: "/videos/44/preview.jpg") == nil)
        manager.storePreview(Data([0xAA, 0xBB]), for: 44, path: "/videos/44/preview.jpg")
        let url = try #require(manager.cachedPreviewURL(for: 44, path: "/videos/44/preview.jpg"))
        #expect(try Data(contentsOf: url) == Data([0xAA, 0xBB]))
        #expect(manager.cachedPreviewURL(for: 45, path: "/videos/44/preview.jpg") == nil)
    }

    @Test func previewFailureStillCachesVideo() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset(payload: Data([0x09]))
        RangeDownloadProtocol.responseOverride = { req in
            if req.url!.host == "img.test" { throw URLError(.timedOut) }
            return try RangeDownloadProtocol.response(for: req)
        }
        try await manager.download(
            id: 13,
            from: URL(string: "https://srv.test/videos/13/stream")!,
            preview: URL(string: "https://img.test/thumb.jpg")!
        )
        #expect(manager.state(for: 13) == .cached)
        #expect(manager.cachedPreviewURL(for: 13, path: "https://img.test/thumb.jpg") == nil)
    }

    @Test func aClientErrorFailsTheDownloadAndUnpinsIt() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = { (jsonResponse($0.url!, status: 404), Data()) }
        await #expect(throws: APIError.badStatus(404)) {
            try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
        }
        await manager.settleStoreWork()
        #expect(await manager.mediaStore.manifest(key: "1") == nil)
        #expect(manager.resumeInterrupted() == [])
    }

    @Test func cancelThrowsAndReturnsToNotCached() async {
        let manager = CacheManager(root: tempRoot(), configuration: hangingRangeConfig())
        let task = Task {
            try await manager.download(id: 21, from: URL(string: "https://srv.test/videos/21/stream")!)
        }
        while manager.state(for: 21) == .notCached { await Task.yield() }
        manager.cancel(id: 21)
        await #expect(throws: Error.self) { try await task.value }
        #expect(manager.state(for: 21) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 21).path))
    }

    @Test func testDownloadSendsBearerToken() async throws {
        RangeDownloadProtocol.reset(payload: Data("video".utf8))
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        try await manager.download(id: 7,
                                   from: URL(string: "https://example.test/videos/7/stream")!,
                                   preview: URL(string: "https://example.test/videos/7/preview")!,
                                   bearerToken: "secret")
        let requests = RangeDownloadProtocol.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
    }

    @Test func fourStreamsSplitTheFileAndReassembleItsBytes() async throws {
        let payload = Data((0..<23).map { UInt8($0) })
        RangeDownloadProtocol.reset(payload: payload)
        let manager = splittingManager(root: tempRoot(), configuration: rangeDownloadConfig())
        try await manager.download(
            id: 50, from: URL(string: "https://srv.test/videos/50/stream")!,
            bearerToken: "secret", streamCount: 4
        )
        let requests = RangeDownloadProtocol.recordedRequests()
        let ranges = requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
        #expect(ranges.first == "bytes=0-0")
        #expect(Set(ranges.dropFirst().prefix(4)) == ["bytes=0-4", "bytes=5-10", "bytes=11-16", "bytes=17-22"])
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == "\"test-video\"" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        #expect(try Data(contentsOf: manager.localURL(for: 50)) == payload)
        #expect(manager.state(for: 50) == .cached)
    }

    @Test func rejectsServerThatIgnoresRangesWithoutPublishingAFile() async {
        RangeDownloadProtocol.reset()
        RangeDownloadProtocol.responseOverride = { request in
            let data = Data("full body".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Length": "\(data.count)"])!, data)
        }
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        await #expect(throws: IdentityProbeError.invalid) {
            try await manager.download(id: 51, from: URL(string: "https://srv.test/videos/51/stream")!, streamCount: 2)
        }
        #expect(manager.state(for: 51) == .notCached)
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 51).path))
    }

    @Test func transientSegmentBlipRetriesAndCompletesDownload() async throws {
        SegmentBlipThenSucceedProtocol.reset()
        // minPiece 4: the 8-byte file splits into 0-3 and 4-7, and neither
        // half is split again, so the retry of 0-3 cannot be stolen into 0-1.
        let manager = CacheManager(root: tempRoot(), configuration: segmentBlipConfig(), fileManager: .default,
                                   fetchTuning: DownloadTuning(minPiece: 4))
        try await manager.download(id: 70, from: URL(string: "https://srv.test/videos/70/stream")!, streamCount: 2)
        let expected = Data((0..<UInt8(SegmentBlipThenSucceedProtocol.total)).map { $0 })
        #expect(try Data(contentsOf: manager.localURL(for: 70)) == expected)
        #expect(manager.state(for: 70) == .cached)
        // The 0-3 range blipped once and was retried in place; nothing had
        // been committed, so the retry asks for the same range again.
        #expect(SegmentBlipThenSucceedProtocol.attempts(forRange: "bytes=0-3") == 2)
        #expect(SegmentBlipThenSucceedProtocol.attempts(forRange: "bytes=4-7") == 1)
    }

    @Test func aVideoWatchedToTheEndReadsAsCached() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let body = sampleBody(10)
        let generation = try await manager.mediaStore.open(key: "40", identity: MediaIdentity(etag: "\"w\"", totalByteCount: 10))
        try await put(manager.mediaStore, key: "40", DownloadByteRange(start: 0, end: 9), generation: generation, from: body)
        #expect(manager.state(for: 40) == .cached)
    }

    @Test func aPartlyWatchedVideoIsNotADownload() async throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let generation = try await manager.mediaStore.open(key: "41", identity: MediaIdentity(etag: "\"w\"", totalByteCount: 10))
        try await put(manager.mediaStore, key: "41", DownloadByteRange(start: 0, end: 4), generation: generation, from: sampleBody(10))
        #expect(manager.state(for: 41) == .notCached)
        #expect(manager.activeDownloads().isEmpty)
    }

    @Test func removeCachedDeletesOnlyRequestedVersion() throws {
        let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())
        let base = manager.localURL(for: 7)
        let version = manager.localURL(for: 7, versionId: 2)
        try Data([0x01]).write(to: base)
        try Data([0x02]).write(to: version)
        manager.removeCached(id: 7, versionId: 2)
        #expect(FileManager.default.fileExists(atPath: base.path))
        #expect(!FileManager.default.fileExists(atPath: version.path))
    }

    @Test func hasAnyCachedFindsBaseAndVersionedFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        #expect(manager.hasAnyCached(id: 21) == false)
        try Data([0x01]).write(to: root.appendingPathComponent("21.v3.mp4"))
        #expect(manager.hasAnyCached(id: 21))
        try Data([0x01]).write(to: root.appendingPathComponent("2.mp4"))
        #expect(manager.hasAnyCached(id: 2))
        #expect(manager.hasAnyCached(id: 1) == false)
    }

    @Test func hasAnyCachedIgnoresPreviewFiles() throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        try Data([0x01]).write(to: root.appendingPathComponent("22.preview.jpg"))
        #expect(manager.hasAnyCached(id: 22) == false)
    }

    @Test func removeAllCachedDeletesVideosAndStoreEntriesKeepsPreviews() async throws {
        let root = tempRoot()
        let manager = CacheManager(root: root, configuration: rangeDownloadConfig())
        let keep = ["23.preview.jpg", "poster.abc123.jpg", "24.mp4"]
        let remove = ["23.mp4", "23.v1.mp4", "23.v12.mp4"]
        for name in keep + remove {
            try Data([0x01]).write(to: root.appendingPathComponent(name))
        }
        let identity = MediaIdentity(etag: "\"r\"", totalByteCount: 4)
        for key in ["23", "23:4", "24:1"] { _ = try await manager.mediaStore.open(key: key, identity: identity) }

        manager.removeAllCached(id: 23)
        await manager.settleStoreWork()

        for name in remove {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "should have deleted \(name)")
        }
        for name in keep {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), "should have kept \(name)")
        }
        #expect(await manager.mediaStore.manifest(key: "23") == nil)
        #expect(await manager.mediaStore.manifest(key: "23:4") == nil)
        #expect(await manager.mediaStore.manifest(key: "24:1") != nil)
        #expect(manager.state(for: 23) == .notCached)
    }

    @Test func clearAllVideosRemovesVideosAndKeepsCovers() async throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["1.mp4", "2.v5.mp4", "1.resume", "2:5.resume", "download-completions.json",
                     "1.preview.jpg", "poster.abc123.jpg"]
        for name in files {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)
        _ = try await manager.mediaStore.open(key: "3", identity: MediaIdentity(etag: "\"c\"", totalByteCount: 4))

        manager.clearAllVideos()
        await manager.settleStoreWork()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for gone in ["1.mp4", "2.v5.mp4", "1.resume", "2:5.resume", "download-completions.json"] {
            #expect(!remaining.contains(gone), "should have deleted \(gone)")
        }
        #expect(remaining.contains("1.preview.jpg"))
        #expect(remaining.contains("poster.abc123.jpg"))
        #expect(await manager.mediaStore.manifest(key: "3") == nil)
    }

    // PASTE the six poster tests from the old suite here, unchanged.

    @Test func clearAllCoversRemovesImagesAndKeepsVideos() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["1.preview.jpg", "poster.abc123.png", "1.mp4"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let manager = CacheManager(root: root)
        manager.clearAllCovers()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains("1.preview.jpg"))
        #expect(!remaining.contains("poster.abc123.png"))
        #expect(remaining.contains("1.mp4"))
    }
}
```

(`clearAllCoversRemovesImagesAndKeepsVideos` no longer lists `1.resume`: the launch migration deletes `.resume` files before the test could check them.)

- [ ] **Step 3: Delete the suites for removed internals**

```bash
git rm ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerSegmentSinkTests.swift \
       ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamCacheSeedTests.swift
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests`
Expected: compile errors, e.g. `value of type 'CacheManager' has no member 'mediaStore'` and `extra argument 'fetchTuning'`.

- [ ] **Step 5: Rewrite CacheManager.swift**

Replace the whole file with:

```swift
import CryptoKit
import Foundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

/// Offline videos: downloads and their pause/resume/cancel, deletion, and the
/// state the UI shows for each video.
///
/// Since 2.9 a download is a **pinned entry** in the `MediaStore` that the
/// stream proxy also reads and writes. `DownloadJobRunner` fills its holes,
/// and whatever closes the last one (a download or watching) renames it to
/// `localURL`. This class keeps only what the UI must read synchronously —
/// running jobs, a mirror of pinned entries, progress — under `lock`, and
/// sends every store write through one serial queue so they land in call
/// order: a cancel followed at once by a new download can never reach the
/// store reversed.
public final class CacheManager: @unchecked Sendable {
    private enum StopReason {
        case paused
        case cancelled
    }

    /// One running download. `stopReason` and `task` are touched only under
    /// `CacheManager.lock`.
    private final class RunningJob: @unchecked Sendable {
        let params: DownloadJobParameters
        var stopReason: StopReason?
        var task: Task<Void, Error>?

        init(params: DownloadJobParameters) {
            self.params = params
        }
    }

    /// The UI's synchronous view of a pinned store entry.
    private struct PinnedRecord {
        var params: DownloadJobParameters
        var paused: Bool
        var progress: Double
        var transferredByteCount: Int64
        var totalByteCount: Int64?
    }

    private let root: URL
    private let store: MediaStore
    private let session: URLSession
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let credentials: CredentialStore?
    private let tuning: DownloadTuning
    private let lock = NSLock()
    let concurrencyGate: any DownloadConcurrencyGating
    private var inFlight = InFlightActivities()
    private var completionHistory: DownloadCompletionHistoryStore
    private var jobs: [String: RunningJob] = [:]
    private var pinned: [String: PinnedRecord] = [:]
    /// Keys whose `download` is waiting at the gate, so `resumeInterrupted`
    /// on a quick background/foreground does not queue them twice.
    private var queuedKeys: Set<String> = []
    private var storeChain: Task<Void, Never>?
    /// Paused keys. A paused download keeps its gate permit (as in 2.8).
    private var pausedKeys: Set<String> = []
    /// Paused keys currently holding a gate permit.
    private var pausedPermitKeys: Set<String> = []
    /// Keys a pause claimed permit ownership of; survives the moment `resume`
    /// clears `pausedKeys`, so a slow unwind's `releasePermit` hands the
    /// permit to the resumed transfer rather than to the gate.
    private var permitOwnerKeys: Set<String> = []
    /// Launch-time permit reservations for entries paused in a past process.
    private var pausedReservations: [String: Task<Void, Never>] = [:]

    /// Session config for downloads. `waitsForConnectivity` parks a retry
    /// during an outage instead of failing at once. (Playback uses
    /// `StreamProxy.defaultSession`, which never waits.)
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return configuration
    }

    public convenience init(
        root: URL? = nil,
        configuration: URLSessionConfiguration = CacheManager.defaultConfiguration(),
        credentials: CredentialStore? = nil
    ) {
        self.init(
            root: root,
            configuration: configuration,
            fileManager: .default,
            credentials: credentials,
            // Only the real app root owns the real 2.8 stream cache.
            legacyStreamRoot: root == nil
                ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("stream", isDirectory: true)
                : nil
        )
    }

    init(
        root: URL?,
        configuration: URLSessionConfiguration,
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date = Date.init,
        concurrencyGate: any DownloadConcurrencyGating = DownloadConcurrencyGate(limit: 3),
        credentials: CredentialStore? = nil,
        legacyStreamRoot: URL? = nil,
        storeTuning: MediaStore.Tuning = MediaStore.Tuning(),
        budgetBytes: Int64 = MediaStore.defaultBudgetBytes,
        fetchTuning: DownloadTuning = DownloadTuning()
    ) {
        let resolvedRoot = root ?? fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        try? fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but out of iCloud/device
        // backups — these MP4s are re-downloadable, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = resolvedRoot
        try? directory.setResourceValues(values)
        LegacyCacheMigration.run(videosRoot: resolvedRoot, legacyStreamRoot: legacyStreamRoot, now: now())

        self.root = resolvedRoot
        self.fileManager = fileManager
        self.now = now
        self.concurrencyGate = concurrencyGate
        self.credentials = credentials
        self.tuning = fetchTuning
        self.store = MediaStore(videosRoot: resolvedRoot, budgetBytes: budgetBytes, tuning: storeTuning, now: now)
        self.session = URLSession(configuration: configuration)
        self.completionHistory = DownloadCompletionHistoryStore(root: resolvedRoot, fileManager: fileManager)

        for manifest in MediaStore.loadManifests(storeRoot: MediaStore.storeRoot(videosRoot: resolvedRoot)) {
            guard let pin = manifest.pin else { continue }
            pinned[manifest.key] = PinnedRecord(
                params: pin.job,
                paused: pin.paused,
                progress: manifest.progress,
                transferredByteCount: manifest.committed.totalBytes,
                totalByteCount: manifest.identity?.totalByteCount
            )
            if pin.paused { pausedKeys.insert(manifest.key) }
        }
        for key in pausedKeys { reservePermit(for: key) }
    }

    /// The store `StreamProxy` reads and writes — the same one downloads fill.
    public var mediaStore: MediaStore { store }

    /// Sets the global cap on how many videos download at once.
    public func setMaxConcurrentDownloads(_ n: Int) {
        concurrencyGate.setLimit(n)
    }

    public var maxConcurrentDownloads: Int {
        concurrencyGate.currentLimit
    }

    /// Directory holding the cached videos, for free-space checks.
    public var cacheRootURL: URL { root }

    public func localURL(for id: Int, versionId: Int? = nil) -> URL {
        root.appendingPathComponent(MediaKey.finishedFilename(cacheKey(videoId: id, versionId: versionId)))
    }

    public var videosRoot: URL { root }

    var urlSession: URLSession { session }

    // MARK: - Previews and posters (unchanged from 2.8)

    /// Local file URL of a cached preview image, or nil if none is cached.
    /// Version-aware: the filename embeds a hash of the preview URL.
    public func cachedPreviewURL(for id: Int, path: String?) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let prefix = path.map { "\(id).preview.\(posterHash($0))." } ?? "\(id).preview."
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func storePreview(_ data: Data, for id: Int, path: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = "\(id).preview."
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let destination = root.appendingPathComponent("\(id).preview.\(posterHash(path)).\(safeExt(from: path))")
        try? data.write(to: destination)
    }

    public func cachedShowPosterURL(for key: String) -> URL? {
        let prefix = "poster.\(posterHash(key))."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func storeShowPoster(_ data: Data, for key: String) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("poster.\(posterHash(key)).\(safeExt(from: key))")
        try? fileManager.removeItem(at: destination)
        try? data.write(to: destination)
    }

    // MARK: - State

    /// `.cached` once the finished mp4 exists, however it got there.
    /// `.downloading` for a running or paused download. A partly watched
    /// video, or a pinned download whose last attempt failed, is
    /// `.notCached`: the download button shows, and tapping it continues
    /// from the committed bytes.
    public func state(for id: Int, versionId: Int? = nil) -> CacheState {
        let key = cacheKey(videoId: id, versionId: versionId)
        if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
        return lock.withLock {
            if jobs[key] != nil { return .downloading(inFlight[key]?.activity.progress ?? 0) }
            if let record = pinned[key], record.paused { return .downloading(record.progress) }
            return .notCached
        }
    }

    /// Live transfers plus paused downloads, sorted by key. A paused entry
    /// whose file has landed anyway (a pause that raced a completion) is
    /// dropped here, and its permit returned.
    public func activeDownloads() -> [DownloadActivity] {
        let (live, paused) = lock.withLock {
            (inFlight.values.map(\.activity), pinned.filter { $0.value.paused && jobs[$0.key] == nil })
        }
        let liveKeys = Set(live.map(\.id))
        var stale: [String] = []
        var rows: [DownloadActivity] = []
        for (key, record) in paused where !liveKeys.contains(key) {
            let id = MediaKey.videoId(of: key)
            let version = MediaKey.versionId(of: key)
            if fileManager.fileExists(atPath: localURL(for: id, versionId: version).path) {
                stale.append(key)
                continue
            }
            rows.append(DownloadActivity(
                videoID: id,
                versionID: version,
                progress: record.progress,
                transferredByteCount: record.transferredByteCount,
                totalByteCount: record.totalByteCount,
                isPaused: true
            ))
        }
        stale.forEach(forgetPin)
        return (live + rows).sorted { $0.id < $1.id }
    }

    /// Total bytes committed by downloads since launch. Monotonic by
    /// construction; feed it to `DownloadSpeedMeter`.
    public func downloadedByteCount() -> Int64 {
        lock.withLock {
            DevLog.event(.download, "byte counter read", inFlight.counterMeta)
            return inFlight.cumulativeByteCount
        }
    }

    public func recentDownloads() -> [DownloadCompletion] {
        lock.withLock {
            completionHistory.prune { completion in
                fileManager.fileExists(atPath: localURL(
                    for: completion.videoID,
                    versionId: completion.versionID
                ).path)
            }
        }
    }

    // MARK: - Downloading

    public func download(id: Int, versionId: Int? = nil, from remote: URL, preview: URL? = nil,
                         showPosterKey: String? = nil, showPoster: URL? = nil,
                         bearerToken: String? = nil, streamCount: Int = 1) async throws {
        DevLog.event(.download, "download requested", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "streams": "\(streamCount)",
            "state": DevLog.describe(state(for: id, versionId: versionId)),
        ])
        let key = cacheKey(videoId: id, versionId: versionId)
        let params = DownloadJobParameters(
            remoteURL: remote,
            streamCount: min(max(streamCount, 1), 4),
            previewURL: preview,
            showPosterKey: showPosterKey,
            showPosterURL: showPoster
        )
        lock.withLock { _ = queuedKeys.insert(key) }
        await concurrencyGate.acquire()
        lock.withLock { _ = queuedKeys.remove(key) }
        DevLog.event(.download, "download passed gate", ["video_id": "\(id)"])
        defer {
            DevLog.event(.download, "download releasing gate", ["video_id": "\(id)"])
            releasePermit(for: key)
        }
        try await performDownload(key: key, params: params, bearerToken: bearerToken)
    }

    /// The transfer, with no gate interaction: `download` wraps it in an
    /// acquire/release; `resume` reuses the permit the paused entry holds.
    private func performDownload(key: String, params: DownloadJobParameters, bearerToken: String?) async throws {
        let id = MediaKey.videoId(of: key)
        if !fileManager.fileExists(atPath: store.finishedURL(key: key).path) {
            try await runJob(key: key, params: params, bearerToken: bearerToken)
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview = params.previewURL {
            try? await cachePreview(id: id, from: preview, bearerToken: bearerToken)
        }
        if let posterKey = params.showPosterKey, let poster = params.showPosterURL,
           cachedShowPosterURL(for: posterKey) == nil {
            try? await cacheShowPoster(key: posterKey, from: poster, bearerToken: bearerToken)
        }
    }

    /// Starts the job for `key`, or joins the one already running.
    private func runJob(key: String, params: DownloadJobParameters, bearerToken: String?) async throws {
        let runner = DownloadJobRunner(
            store: store,
            key: key,
            streamCount: params.streamCount,
            session: session,
            upstream: UpstreamRequests(url: params.remoteURL, credentials: credentials, fallbackToken: bearerToken),
            tuning: tuning,
            onProgress: { [weak self] manifest in self?.recordProgress(key: key, manifest: manifest) }
        )
        let (job, task, created) = lock.withLock { () -> (RunningJob, Task<Void, Error>, Bool) in
            if let existing = jobs[key], let task = existing.task { return (existing, task, false) }
            let job = RunningJob(params: params)
            jobs[key] = job
            let previous = pinned[key]
            pinned[key] = PinnedRecord(
                params: params,
                paused: false,
                progress: previous?.progress ?? 0,
                transferredByteCount: previous?.transferredByteCount ?? 0,
                totalByteCount: previous?.totalByteCount
            )
            inFlight[key] = DownloadActivityAccumulator(
                videoID: MediaKey.videoId(of: key),
                versionID: MediaKey.versionId(of: key),
                totalByteCount: previous?.totalByteCount
            )
            let pinWritten = enqueueStoreWorkLocked { await $0.setPin(key: key, pin: PinState(job: params, paused: false)) }
            let task = Task {
                await pinWritten.value
                try await runner.run()
            }
            job.task = task
            return (job, task, true)
        }
        do {
            try await task.value
            if created { finishJob(key: key, job: job, error: nil) }
        } catch {
            if created { finishJob(key: key, job: job, error: error) }
            let reason = lock.withLock { job.stopReason }
            switch reason {
            case .paused: throw DownloadPausedError()
            case .cancelled: throw CancellationError()
            case nil: throw error
            }
        }
    }

    private func recordProgress(key: String, manifest: MediaEntryManifest) {
        lock.withLock {
            guard jobs[key] != nil else { return }
            inFlight[key]?.record(
                transferredByteCount: manifest.committed.totalBytes,
                progress: manifest.progress,
                totalByteCount: manifest.identity?.totalByteCount
            )
            pinned[key]?.progress = manifest.progress
            pinned[key]?.transferredByteCount = manifest.committed.totalBytes
            pinned[key]?.totalByteCount = manifest.identity?.totalByteCount
        }
    }

    /// Only the job's creator finishes it, and only while it is still the
    /// current job: a pause or cancel already moved the table on.
    private func finishJob(key: String, job: RunningJob, error: Error?) {
        let unpin: Bool = lock.withLock {
            guard jobs[key] === job else { return false }
            jobs[key] = nil
            inFlight[key] = nil
            guard let error else {
                pinned[key] = nil
                completionHistory.record(DownloadCompletion(
                    videoID: MediaKey.videoId(of: key),
                    versionID: MediaKey.versionId(of: key),
                    completedAt: now()
                ))
                return false // promotion already removed the entry
            }
            if case .badStatus(let status)? = error as? APIError, (400..<500).contains(status) {
                pinned[key] = nil
                return true // the server will not have it on a retry either
            }
            return false // stays pinned with its bytes; the next tap or resumeInterrupted continues
        }
        if unpin { enqueueStoreWork { await $0.discard(key: key) } }
        DevLog.event(.download, error == nil ? "download finished" : "download failed", [
            "key": key, "err": error.map { "\($0)" } ?? "-",
        ])
    }

    /// Suspends a download, keeping its committed bytes **and** its gate
    /// permit. The parameters are stored because a resume may come in a
    /// later process.
    public func pause(
        id: Int,
        versionId: Int? = nil,
        remote: URL,
        streamCount: Int,
        preview: URL? = nil,
        showPosterKey: String? = nil,
        showPoster: URL? = nil
    ) {
        let key = cacheKey(videoId: id, versionId: versionId)
        let outcome = lock.withLock { () -> (task: Task<Void, Error>?, progress: Double)? in
            guard !pausedKeys.contains(key) else { return nil }
            let job = jobs[key]
            let params = job?.params ?? pinned[key]?.params ?? DownloadJobParameters(
                remoteURL: remote,
                streamCount: min(max(streamCount, 1), 4),
                previewURL: preview,
                showPosterKey: showPosterKey,
                showPosterURL: showPoster
            )
            let activity = inFlight[key]?.activity
            let previous = pinned[key]
            let record = PinnedRecord(
                params: params,
                paused: true,
                progress: activity?.progress ?? previous?.progress ?? 0,
                transferredByteCount: activity?.transferredByteCount ?? previous?.transferredByteCount ?? 0,
                totalByteCount: activity?.totalByteCount ?? previous?.totalByteCount
            )
            pinned[key] = record
            pausedKeys.insert(key)
            permitOwnerKeys.insert(key)
            job?.stopReason = .paused
            jobs[key] = nil
            inFlight[key] = nil
            _ = enqueueStoreWorkLocked { await $0.setPin(key: key, pin: PinState(job: params, paused: true)) }
            return (job?.task, record.progress)
        }
        guard let outcome else { return }
        DevLog.event(.download, "pause", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "progress": String(format: "%.3f", outcome.progress),
        ])
        outcome.task?.cancel()
    }

    /// Restarts a paused download on the permit it has been holding. Only
    /// the Resume menu item calls this.
    public func resume(id: Int, versionId: Int? = nil, bearerToken: String? = nil) async throws {
        let key = cacheKey(videoId: id, versionId: versionId)
        guard lock.withLock({ pinned[key]?.paused == true }) else { return }
        // Can block while more entries are paused than the gate allows, so
        // nothing is claimed before it returns.
        await awaitPermit(for: key)
        guard let params = lock.withLock({ () -> DownloadJobParameters? in
            guard let record = pinned[key], record.paused else { return nil }
            pinned[key]?.paused = false
            pausedKeys.remove(key)
            return record.params
        }) else { return }
        DevLog.event(.download, "resume", [
            "video_id": "\(id)", "version_id": versionId.map(String.init) ?? "-",
        ])
        defer { releasePausedPermit(for: key) }
        try await performDownload(key: key, params: params, bearerToken: bearerToken)
    }

    /// Restarts pinned, unpaused downloads that are not running: those the
    /// app was suspended or killed during, and those whose last attempt
    /// failed. Each goes through the gate like any download. Call on launch
    /// and on every activation. Returns the video ids restarted.
    @discardableResult
    public func resumeInterrupted(bearerToken: String? = nil) -> [Int] {
        let pending = lock.withLock {
            pinned.filter { !$0.value.paused && jobs[$0.key] == nil && !queuedKeys.contains($0.key) }
        }
        for (key, record) in pending {
            let params = record.params
            Task { [weak self] in
                try? await self?.download(
                    id: MediaKey.videoId(of: key),
                    versionId: MediaKey.versionId(of: key),
                    from: params.remoteURL,
                    preview: params.previewURL,
                    showPosterKey: params.showPosterKey,
                    showPoster: params.showPosterURL,
                    bearerToken: bearerToken,
                    streamCount: params.streamCount
                )
            }
        }
        let ids = Array(Set(pending.keys.map(MediaKey.videoId(of:)))).sorted()
        DevLog.event(.download, "resumeInterrupted", [
            "resumed": "\(ids.count)",
            "ids": ids.prefix(20).map(String.init).joined(separator: ","),
            "free_bytes": DevLog.freeDiskBytes(),
        ])
        return ids
    }

    // MARK: - Cancel and delete

    /// Stops a download and unpins it. Its bytes go once no player response
    /// reads them. The awaiting `download` throws `CancellationError`.
    public func cancel(id: Int, versionId: Int? = nil) {
        DevLog.event(.cache, "cancel", [
            "video_id": "\(id)",
            "version_id": versionId.map(String.init) ?? "-",
            "state": DevLog.describe(state(for: id, versionId: versionId)),
        ])
        discardDownload(key: cacheKey(videoId: id, versionId: versionId))
    }

    private func discardDownload(key: String) {
        let (task, wasPaused) = lock.withLock { () -> (Task<Void, Error>?, Bool) in
            let wasPaused = pausedKeys.remove(key) != nil
            let job = jobs.removeValue(forKey: key)
            job?.stopReason = .cancelled
            inFlight[key] = nil
            pinned[key] = nil
            _ = enqueueStoreWorkLocked { await $0.discard(key: key) }
            return (job?.task, wasPaused)
        }
        if wasPaused { releasePausedPermit(for: key) }
        task?.cancel()
    }

    /// Drops a pin whose file landed anyway: the mirror, the permit, the flag.
    private func forgetPin(_ key: String) {
        lock.withLock {
            pinned[key] = nil
            _ = pausedKeys.remove(key)
        }
        releasePausedPermit(for: key)
        enqueueStoreWork { await $0.setPin(key: key, pin: nil) }
    }

    /// Deletes a downloaded video (and any store entry for it).
    public func removeCached(id: Int, versionId: Int? = nil) {
        DevLog.event(.cache, "removeCached", [
            "video_id": "\(id)", "version_id": versionId.map(String.init) ?? "-",
        ])
        discardDownload(key: cacheKey(videoId: id, versionId: versionId))
        try? fileManager.removeItem(at: localURL(for: id, versionId: versionId))
    }

    /// True when any cached MP4 exists for this video.
    public func hasAnyCached(id: Int) -> Bool {
        !cachedVideoFilenames(id: id).isEmpty
    }

    /// Deletes every cached MP4 and store entry for this video. Previews and
    /// posters are kept — small, still useful offline.
    public func removeAllCached(id: Int) {
        DevLog.event(.cache, "removeAllCached", ["video_id": "\(id)"])
        let keys = lock.withLock { Set(jobs.keys).union(pinned.keys).filter { MediaKey.videoId(of: $0) == id } }
        keys.forEach(discardDownload)
        for name in cachedVideoFilenames(id: id) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        enqueueStoreWork { await $0.discardAll(videoId: id) }
    }

    /// One-time cleanup of the HLS era (<= 2.8): deletes every offline HLS
    /// package and the `.hls-tmp` staging dir, and returns the ids to
    /// download again as mp4. Idempotent.
    public func removeLegacyHLSPackages() -> [Int] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var ids = Set(PausedDownloadStore.droppedHLSVideoIDs(root: root))
        for name in contents where name.hasPrefix("hls-") {
            let digits = name.dropFirst("hls-".count).prefix { $0.isNumber }
            if let id = Int(digits) { ids.insert(id) }
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let staging = root.appendingPathComponent(".hls-tmp", isDirectory: true)
        if let staged = try? fileManager.contentsOfDirectory(atPath: staging.path) {
            for key in staged { ids.insert(MediaKey.videoId(of: key)) }
        }
        try? fileManager.removeItem(at: staging)
        PausedDownloadStore.clearDroppedHLS(root: root)
        let pending = ids.filter { !hasAnyCached(id: $0) }.sorted()
        if !pending.isEmpty {
            DevLog.event(.cache, "legacy HLS removed", [
                "ids": pending.map(String.init).joined(separator: ","),
            ])
        }
        return pending
    }

    /// Cancels every download and deletes every MP4, store entry and the
    /// completion history. Previews and posters stay (see `clearAllCovers`).
    public func clearAllVideos() {
        let keys = lock.withLock { Set(jobs.keys).union(pinned.keys) }
        DevLog.event(.cache, "clearAllVideos", ["downloads": "\(keys.count)"])
        keys.forEach(discardDownload)
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.hasSuffix(".mp4") || name.hasPrefix("hls-") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        enqueueStoreWork { await $0.discardAll() }
        lock.withLock { completionHistory.clear() }
    }

    public func clearAllCovers() {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents where name.contains(".preview.") || name.hasPrefix("poster.") {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func cachedVideoFilenames(id: Int) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return contents.filter {
            $0 == "\(id).mp4" || ($0.hasPrefix("\(id).v") && $0.hasSuffix(".mp4"))
        }
    }

    // MARK: - Store work queue

    @discardableResult
    private func enqueueStoreWork(_ work: @escaping @Sendable (MediaStore) async -> Void) -> Task<Void, Never> {
        lock.withLock { enqueueStoreWorkLocked(work) }
    }

    /// Store writes run one at a time in call order. Caller holds `lock`.
    private func enqueueStoreWorkLocked(_ work: @escaping @Sendable (MediaStore) async -> Void) -> Task<Void, Never> {
        let previous = storeChain
        let store = self.store
        let task = Task {
            await previous?.value
            await work(store)
        }
        storeChain = task
        return task
    }

    /// Waits for every store write queued so far.
    public func settleStoreWork() async {
        let last = lock.withLock { storeChain }
        await last?.value
    }

    // MARK: - Gate permits for paused downloads (unchanged from 2.8)

    /// Returns a finished download's permit — unless the key was paused, in
    /// which case ownership moves to the paused-permit table and the slot
    /// stays occupied.
    func releasePermit(for key: String) {
        let handedOver = lock.withLock { () -> Bool in
            guard pausedKeys.contains(key) || permitOwnerKeys.contains(key),
                  !pausedPermitKeys.contains(key)
            else { return false }
            pausedPermitKeys.insert(key)
            return true
        }
        DevLog.event(.download, handedOver ? "permit held for pause" : "permit released", ["key": key])
        if !handedOver { concurrencyGate.release() }
    }

    /// Re-acquires a permit for an entry paused in a previous process.
    private func reservePermit(for key: String) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.concurrencyGate.acquire()
            let stillPaused = self.lock.withLock { () -> Bool in
                guard self.pausedKeys.contains(key) else { return false }
                self.pausedPermitKeys.insert(key)
                return true
            }
            if !stillPaused { self.concurrencyGate.release() }
        }
        lock.withLock { pausedReservations[key] = task }
    }

    func awaitPermit(for key: String) async {
        guard let task = lock.withLock({ pausedReservations[key] }) else { return }
        await task.value
    }

    func releasePausedPermit(for key: String) {
        let held = lock.withLock { () -> Bool in
            permitOwnerKeys.remove(key)
            return pausedPermitKeys.remove(key) != nil
        }
        lock.withLock { pausedReservations[key] = nil }
        if held { concurrencyGate.release() }
    }

    // MARK: - Helpers

    func cacheKey(videoId: Int, versionId: Int?) -> String {
        Self.cacheKey(videoId: videoId, versionId: versionId)
    }

    static func cacheKey(videoId: Int, versionId: Int?) -> String {
        MediaKey.key(videoId: videoId, versionId: versionId)
    }

    func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        storePreview(data, for: id, path: remote.absoluteString)
    }

    func cacheShowPoster(key: String, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        storeShowPoster(data, for: key)
    }

    private func posterHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private func safeExt(from urlString: String) -> String {
        let ext = (URL(string: urlString)?.pathExtension ?? "").lowercased()
        return (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
    }
}

extension CacheManager: MediaCaching {}
```

- [ ] **Step 6: Point the app at the new initializer**

In `ios/PatataTube/Sources/AppModel.swift`, replace:

```swift
        let cache = CacheManager(root: cacheRoot, streamCache: streamCache)
```

with:

```swift
        let cache = CacheManager(root: cacheRoot, credentials: credentials)
```

`streamCache` stays for one more task: the old proxy still uses it until Task 10.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "CacheManager"`
Expected: `CacheManagerTests`, `CacheManagerPauseTests`, `CacheManagerConcurrencyGateTests`, `CacheManagerByteCounterTests` and `CacheManagerLegacyHLSTests` all pass.

Then check the app target still compiles:

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerPauseTests.swift \
        ios/PatataTube/Sources/AppModel.swift
git commit -m "kit: downloads are pinned entries in the media store

CacheManager keeps its public API; segmented part files, resume data
and pause teardown are gone. Pause keeps committed ranges and the gate
permit, resume refills the holes, cancel unpins and deletes once no
player reads the entry.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(`git rm` from Step 3 already staged the two deleted suites.)

---

### Task 10: Streaming StreamProxy, app wiring, cache statistics

**Files:**
- Rewrite: `Sources/PatataTubeKit/StreamProxy.swift`
- Create: `Sources/PatataTubeKit/ProxyBody.swift`
- Modify: `Sources/PatataTubeKit/CacheStatistics.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`
- Rewrite: `Tests/PatataTubeKitTests/StreamProxyTests.swift`
- Modify: `Tests/PatataTubeKitTests/CacheStatisticsCollectorTests.swift`

- [ ] **Step 1: Rewrite the proxy tests (failing)**

Replace the whole of `Tests/PatataTubeKitTests/StreamProxyTests.swift` with:

```swift
import XCTest
@testable import PatataTubeKit

private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as! HTTPURLResponse)
}

final class StreamProxyTests: XCTestCase {
    private var root: URL!
    private var store: MediaStore!
    private var credentials: CredentialStore!
    private var proxy: StreamProxy!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = MediaStore(videosRoot: root)
        credentials = InMemoryCredentialStore(baseURL: URL(string: "https://upstream.test"), token: "tok")
        proxy = await makeProxy(store: store, protocolClass: MockURLProtocol.self)
    }

    override func tearDown() async throws {
        await proxy.stop()
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeProxy(store: MediaStore, protocolClass: AnyClass,
                           tuning: StreamProxy.Tuning = StreamProxy.Tuning()) async -> StreamProxy {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let proxy = StreamProxy(store: store, credentials: credentials,
                                session: URLSession(configuration: config), tuning: tuning)
        await proxy.start()
        return proxy
    }

    private func smallTuning(waitWithin: Int64) -> StreamProxy.Tuning {
        var tuning = StreamProxy.Tuning()
        tuning.commitSize = 1024
        tuning.readSize = 1024
        tuning.waitWithin = waitWithin
        return tuning
    }

    func testWrongSecretIs404() async throws {
        let good = proxy.mp4URL(videoId: 5, versionId: nil)!
        let bad = URL(string: good.absoluteString.replacingOccurrences(of: proxy.secret, with: "nope"))!
        let (_, response) = try await get(bad)
        XCTAssertEqual(response.statusCode, 404)
    }

    /// The 2.8 bug: an 8 MB window answered AVPlayer's whole-file request, and
    /// AVPlayer failed the item. The response must cover the whole range.
    func testAWholeFileRequestGetsTheWholeFile() async throws {
        let total = 9 * 1024 * 1024
        let body = sampleBody(total)
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")
        let url = try XCTUnwrap(proxy.mp4URL(videoId: 9, versionId: nil))
        let (data, response) = try await get(url, range: "bytes=0-\(total - 1)")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "\(total)")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(total - 1)/\(total)")
        XCTAssertEqual(data, body)
    }

    func testAnOpenEndedRangeRunsToTheEnd() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/10/stream", fullBody: body, etag: "\"e1\"")
        let (data, response) = try await get(proxy.mp4URL(videoId: 10, versionId: nil)!, range: "bytes=100-")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 100-999/1000")
        XCTAssertEqual(data, body.subdata(in: 100..<1000))
    }

    func testWatchedBytesAreKeptAndServedFromTheStore() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/11/stream", fullBody: body, etag: "\"e1\"")
        let url = proxy.mp4URL(videoId: 11, versionId: nil)!
        let (data, _) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(data, body.subdata(in: 100..<300))
        let count = MockURLProtocol.requestCount(path: "/videos/11/stream")
        let (again, _) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(again, data)
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/11/stream"), count)
    }

    func testAFinishedFileIsServedWithoutTheServer() async throws {
        let body = sampleBody(1000)
        try body.write(to: store.finishedURL(key: "12"))
        let (data, response) = try await get(proxy.mp4URL(videoId: 12, versionId: nil)!, range: "bytes=10-19")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/1000")
        XCTAssertEqual(data, body.subdata(in: 10..<20))
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/12/stream"), 0)
    }

    /// Part committed, part fetched by this reader, part being fetched by a
    /// download: the response is the original bytes, and the reader fetched
    /// only the gap between the two.
    func testAMixedRangeComesBackByteIdentical() async throws {
        let path = "/videos/14/stream"
        let body = sampleBody(4000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"m\"", chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let identity = MediaIdentity(etag: "\"m\"", totalByteCount: 4000)
        let generation = try await store.open(key: "14", identity: identity)
        try await put(store, key: "14", DownloadByteRange(start: 0, end: 999), generation: generation, from: body)
        guard case .granted(let tail) = await store.claim(key: "14", from: 3000, through: 3999, owner: .download, waitWithin: 0)
        else { return XCTFail("tail claim refused") }
        let download = RangeFetcher(
            store: store, key: "14", identity: identity, generation: generation,
            session: URLSession(configuration: ChunkedRangeProtocol.configuration()),
            upstream: UpstreamRequests(url: URL(string: "https://upstream.test\(path)")!, credentials: nil),
            commitSize: 100
        )
        let downloading = Task { try await download.run(claim: tail.id) }
        let chunked = await makeProxy(store: store, protocolClass: ChunkedRangeProtocol.self, tuning: smallTuning(waitWithin: 4000))

        let (data, _) = try await get(chunked.mp4URL(videoId: 14, versionId: nil)!, range: "bytes=0-3999")

        XCTAssertEqual(data, body)
        _ = try await downloading.value
        XCTAssertTrue(ChunkedRangeProtocol.recordedRanges(path: path).contains("bytes=1000-2999"))
        await chunked.stop()
    }

    func testHangingUpCancelsOnlyThatReadersFetcher() async throws {
        let path = "/videos/15/stream"
        let body = sampleBody(200_000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"h\"", chunkSize: 4096,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.01); return true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        _ = try await store.open(key: "15", identity: MediaIdentity(etag: "\"h\"", totalByteCount: 200_000))
        var tuning = smallTuning(waitWithin: 8192)
        tuning.commitSize = 4096
        let chunked = await makeProxy(store: store, protocolClass: ChunkedRangeProtocol.self, tuning: tuning)
        let url = try XCTUnwrap(chunked.mp4URL(videoId: 15, versionId: nil))

        var requestA = URLRequest(url: url)
        requestA.setValue("bytes=0-199999", forHTTPHeaderField: "Range")
        let (bytesA, _) = try await URLSession.shared.bytes(for: requestA)
        var received = 0
        for try await _ in bytesA {
            received += 1
            if received == 4096 { break }
        }
        async let resultB = get(url, range: "bytes=100000-199999")
        try await Task.sleep(for: .milliseconds(50))
        bytesA.task.cancel()

        let (dataB, _) = try await resultB
        XCTAssertEqual(dataB, body.subdata(in: 100_000..<200_000))
        let stopped = await eventually { ChunkedRangeProtocol.stoppedRanges(path: path).contains("bytes=0-199999") }
        XCTAssertTrue(stopped, "reader A's upstream fetch kept running after it hung up")
        XCTAssertFalse(ChunkedRangeProtocol.stoppedRanges(path: path).contains("bytes=100000-199999"))
        await chunked.stop()
    }

    func testAChangedFileEndsTheResponseAndResetsTheEntry() async throws {
        let body = sampleBody(1000)
        MockURLProtocol.registerCounting(path: "/videos/16/stream") { request in
            let etag = request.value(forHTTPHeaderField: "Range") == "bytes=0-0" ? "\"e1\"" : "\"e2\""
            return try rangedResponse(request: request, fullBody: body, etag: etag)
        }
        do {
            _ = try await get(proxy.mp4URL(videoId: 16, versionId: nil)!, range: "bytes=0-999")
            XCTFail("expected the response to end early")
        } catch {}
        let manifest = await store.manifest(key: "16")
        XCTAssertEqual(manifest?.identity?.etag, "\"e2\"")
        XCTAssertEqual(manifest?.committed.totalBytes, 0)
    }

    func testDownloadingWhileWatchingFetchesEachByteOnce() async throws {
        let path = "/videos/17/stream"
        let total = 64 * 1024
        let body = sampleBody(total)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"d\"", chunkSize: 1024,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.002); return true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let otherRoot = temporaryVideosRoot("both")
        let manager = CacheManager(
            root: otherRoot, configuration: ChunkedRangeProtocol.configuration(), fileManager: .default,
            fetchTuning: DownloadTuning(minPiece: 8 * 1024, commitSize: 1024)
        )
        let chunked = await makeProxy(store: manager.mediaStore, protocolClass: ChunkedRangeProtocol.self,
                                      tuning: smallTuning(waitWithin: 8 * 1024))

        async let download: Void = manager.download(id: 17, from: URL(string: "https://upstream.test\(path)")!, streamCount: 2)
        let (data, _) = try await get(chunked.mp4URL(videoId: 17, versionId: nil)!, range: "bytes=0-\(total - 1)")
        try await download

        XCTAssertEqual(data, body)
        XCTAssertEqual(try Data(contentsOf: manager.localURL(for: 17)), body)
        XCTAssertLessThan(ChunkedRangeProtocol.deliveredByteCount(path: path), total + total / 4)
        await chunked.stop()
    }

    func testPlaybackDoesNotWaitForADownloadSlot() async throws {
        let gate = DownloadConcurrencyGate(limit: 1)
        await gate.acquire()
        let otherRoot = temporaryVideosRoot("gate")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = CacheManager(root: otherRoot, configuration: config, fileManager: .default, concurrencyGate: gate)
        MockURLProtocol.stubRanged(path: "/videos/18/stream", fullBody: sampleBody(10), etag: "\"g\"")
        let waiting = Task { try await manager.download(id: 18, from: URL(string: "https://upstream.test/videos/18/stream")!) }
        let body = sampleBody(1000)
        MockURLProtocol.stubRanged(path: "/videos/19/stream", fullBody: body, etag: "\"g\"")
        let playing = await makeProxy(store: manager.mediaStore, protocolClass: MockURLProtocol.self)

        let (data, response) = try await get(playing.mp4URL(videoId: 19, versionId: nil)!, range: "bytes=0-999")

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, body)
        gate.release()
        try await waiting.value
        await playing.stop()
    }

    // MARK: - Listener liveness

    func testServerExitClearsPortSoURLsGoNil() async throws {
        XCTAssertNotNil(proxy.port)
        await proxy.server?.stop()
        let cleared = await pollUntil { self.proxy.port == nil }
        XCTAssertTrue(cleared, "port stayed \(proxy.port.map(String.init) ?? "nil") after listener died")
        XCTAssertNil(proxy.mp4URL(videoId: 5, versionId: nil))
    }

    func testEnsureRunningRestartsAfterListenerDies() async throws {
        await proxy.server?.stop()
        _ = await pollUntil { self.proxy.port == nil }
        await proxy.ensureRunning()
        XCTAssertNotNil(proxy.port)
        MockURLProtocol.stubRanged(path: "/videos/5/stream", fullBody: Data(repeating: 1, count: 64), etag: "\"e1\"")
        let url = try XCTUnwrap(proxy.mp4URL(videoId: 5, versionId: nil))
        let (_, response) = try await get(url, range: "bytes=0-9")
        XCTAssertEqual(response.statusCode, 206)
    }

    func testEnsureRunningKeepsPortWhenAlreadyServing() async throws {
        let port = try XCTUnwrap(proxy.port)
        await proxy.ensureRunning()
        XCTAssertEqual(proxy.port, port)
    }

    private func pollUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private func rangedResponse(request: URLRequest, fullBody: Data, etag: String) throws -> (HTTPURLResponse, Data) {
    guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
        throw URLError(.badServerResponse)
    }
    let bounds = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < fullBody.count else {
        throw URLError(.badServerResponse)
    }
    let requestedEnd = bounds[1].isEmpty ? fullBody.count - 1 : Int(bounds[1])
    guard let requestedEnd, requestedEnd >= start else { throw URLError(.badServerResponse) }
    let end = min(requestedEnd, fullBody.count - 1)
    let data = fullBody.subdata(in: start..<(end + 1))
    return (
        HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Range": "bytes \(start)-\(end)/\(fullBody.count)",
            "ETag": etag,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(data.count)",
        ])!,
        data
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests`
Expected: compile errors, e.g. `incorrect argument label in call (have 'store:credentials:session:tuning:', expected 'cache:credentials:session:')`.

- [ ] **Step 3: Write ProxyBody.swift**

`Sources/PatataTubeKit/ProxyBody.swift`:

```swift
import FlyingSocks
import Foundation

enum ProxyReadError: Error, Equatable {
    case entryGone
    case entityChanged
}

/// What FlyingFox iterates to send one proxied mp4 body. `HTTPBodySequence`
/// pulls it through `nextBuffer(suggested:)`.
struct ProxyBody: AsyncBufferedSequence {
    typealias Element = UInt8

    let reader: ProxyReadSession

    func makeAsyncIterator() -> Iterator {
        Iterator(reader: reader)
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Buffer = Data

        let reader: ProxyReadSession
        private var spare = Data()

        init(reader: ProxyReadSession) {
            self.reader = reader
        }

        mutating func next() async throws -> UInt8? {
            if spare.isEmpty {
                guard let data = try await reader.nextBuffer(maxCount: 64 * 1024) else { return nil }
                spare = data
            }
            return spare.popFirst()
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            if !spare.isEmpty {
                defer { spare = Data() }
                return spare
            }
            return try await reader.nextBuffer(maxCount: count)
        }
    }
}

/// One proxied response's reader. It serves `window` in order: committed
/// bytes from disk; bytes a fetcher close behind is about to commit, by
/// waiting; otherwise bytes from its own playback fetcher at the playhead,
/// parked `readAhead` ahead of what was sent. Released when FlyingFox drops
/// the body (finished or client hung up). It then cancels only the fetcher
/// it started and ends its read on the entry.
///
/// Only FlyingFox's single body iteration calls `nextBuffer`. The lock
/// covers what the fetcher task writes back and what `deinit` reads.
final class ProxyReadSession: @unchecked Sendable {
    private let store: MediaStore?
    private let key: String
    private let identity: MediaIdentity
    private let generation: Int
    private let window: DownloadByteRange
    private let upstream: UpstreamRequests
    private let session: URLSession
    private let tuning: StreamProxy.Tuning

    private var position: Int64
    private var handle: FileHandle?
    private var passthrough: DataTaskStream?
    private var passthroughOnly: Bool

    private let lock = NSLock()
    private var fetcherTask: Task<Void, Never>?
    private var limiter: ReadAheadLimiter?
    private var fetcherResult: Result<FetchOutcome, Error>?

    /// The caller has already called `store.beginRead(key:)`.
    init(store: MediaStore, key: String, identity: MediaIdentity, generation: Int,
         window: DownloadByteRange, upstream: UpstreamRequests, session: URLSession,
         tuning: StreamProxy.Tuning) {
        self.store = store
        self.key = key
        self.identity = identity
        self.generation = generation
        self.window = window
        self.upstream = upstream
        self.session = session
        self.tuning = tuning
        self.position = window.start
        self.passthroughOnly = false
    }

    /// No room in the store even after evicting: stream without keeping.
    init(passthroughOf window: DownloadByteRange, key: String, identity: MediaIdentity,
         upstream: UpstreamRequests, session: URLSession, tuning: StreamProxy.Tuning) {
        self.store = nil
        self.key = key
        self.identity = identity
        self.generation = -1
        self.window = window
        self.upstream = upstream
        self.session = session
        self.tuning = tuning
        self.position = window.start
        self.passthroughOnly = true
    }

    deinit {
        let (task, limiter) = lock.withLock { (fetcherTask, self.limiter) }
        task?.cancel()
        limiter?.cancel()
        passthrough?.cancel()
        try? handle?.close()
        if let store {
            let key = key
            Task { await store.endRead(key: key) }
        }
    }

    func nextBuffer(maxCount: Int) async throws -> Data? {
        while position <= window.end {
            try Task.checkCancellation()
            guard let store, !passthroughOnly else {
                return try await nextPassthrough()
            }
            guard let availability = await store.available(key: key, from: position) else {
                throw ProxyReadError.entryGone
            }
            guard availability.generation == generation else { throw ProxyReadError.entityChanged }
            if availability.bytes > 0 {
                let count = min(Int64(min(maxCount, tuning.readSize)), availability.bytes, window.end - position + 1)
                return try await read(count, store: store)
            }
            if try await handleFetcherResult(store: store) { continue }
            switch await store.claim(
                key: key, from: position, through: window.end, owner: .playback, waitWithin: tuning.waitWithin
            ) {
            case .alreadyCommitted:
                continue
            case .noEntry:
                throw ProxyReadError.entryGone
            case .covered(_, let version):
                await store.waitForChange(key: key, after: version)
            case .granted(let claim):
                startFetcher(claim, store: store)
            }
        }
        return nil
    }

    private func read(_ count: Int64, store: MediaStore) async throws -> Data {
        if handle == nil { handle = await store.openReadHandle(key: key) }
        guard let handle else { throw ProxyReadError.entryGone }
        try handle.seek(toOffset: UInt64(position))
        guard let data = try handle.read(upToCount: Int(count)), !data.isEmpty else {
            throw ProxyReadError.entryGone
        }
        position += Int64(data.count)
        lock.withLock { limiter }?.advance(to: position)
        return data
    }

    /// Consumes the own fetcher's result, if it has ended. True means loop
    /// again at once.
    private func handleFetcherResult(store: MediaStore) async throws -> Bool {
        let result = lock.withLock { () -> Result<FetchOutcome, Error>? in
            guard let result = fetcherResult else { return nil }
            fetcherResult = nil
            fetcherTask = nil
            limiter = nil
            return result
        }
        guard let result else { return false }
        switch result {
        case .success:
            return true
        case .failure(let error):
            if error as? MediaStoreError == .storageFull {
                DevLog.event(.proxy, "store full, passing through", ["key": key])
                passthroughOnly = true
                return true
            }
            if case .entityChanged(let changed)? = error as? RangeFetchError, let changed {
                // Reset now, so the next request starts on the new file.
                _ = try? await store.open(key: key, identity: changed)
            }
            throw error
        }
    }

    private func startFetcher(_ claim: ClaimSnapshot, store: MediaStore) {
        let limiter = ReadAheadLimiter(lead: tuning.readAhead, position: position)
        let fetcher = RangeFetcher(
            store: store, key: key, identity: identity, generation: generation,
            session: session, upstream: upstream,
            commitSize: tuning.commitSize, maxAttempts: tuning.maxAttempts, limiter: limiter
        )
        let key = key
        let task = Task { [weak self] in
            let result: Result<FetchOutcome, Error>
            do {
                result = .success(try await fetcher.run(claim: claim.id))
            } catch {
                result = .failure(error)
            }
            // Record before releasing: the release wakes the reader, which
            // must see why its fetcher stopped.
            if let self { self.lock.withLock { self.fetcherResult = result } }
            await store.releaseClaim(key: key, id: claim.id)
        }
        lock.withLock {
            fetcherTask = task
            self.limiter = limiter
        }
    }

    private func nextPassthrough() async throws -> Data? {
        if passthrough == nil {
            var request = upstream.ranged(DownloadByteRange(start: position, end: window.end))
            request.setValue(identity.etag, forHTTPHeaderField: "If-Range")
            let (response, stream) = try await DataTaskStream.start(request, session: session)
            try RangeFetcher.validate(response, identity: identity, start: position)
            passthrough = stream
        }
        guard let chunk = try await passthrough?.nextChunk() else { throw RangeFetchError.shortBody }
        let usable = chunk.prefix(Int(window.end - position + 1))
        position += Int64(usable.count)
        return usable
    }
}
```

- [ ] **Step 4: Rewrite StreamProxy.swift**

Replace the whole file with:

```swift
import FlyingFox
import FlyingSocks
import Foundation

/// Loopback proxy for AVPlayer. It requests
/// `http://127.0.0.1:{port}/{secret}/mp4/{id}/{v}` and gets the **whole**
/// requested range as one streamed 206, read from and written to the
/// `MediaStore` that downloads share. Before 2.9 this answered with buffered
/// 8 MB windows, and AVPlayer failed every file larger than that.
public final class StreamProxy: @unchecked Sendable {
    public struct Tuning: Sendable {
        /// Wait for a fetcher at most this far behind the playhead rather
        /// than start a second one.
        public var waitWithin: Int64 = 4 * 1_048_576
        /// A playback fetcher parks once this far ahead of what was sent.
        public var readAhead: Int64 = 32 * 1_048_576
        public var readSize = 256 * 1024
        public var commitSize = 256 * 1024
        /// 1 + 2 retries, then the response ends early and AVPlayer retries.
        public var maxAttempts = 3

        public init() {}
    }

    /// Playback never waits for connectivity: a hole while offline must
    /// error in seconds, not hang. Committed bytes still play.
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    public let secret = UUID().uuidString
    private let store: MediaStore
    private let credentials: CredentialStore
    private let session: URLSession
    private let tuning: Tuning
    private let lock = NSLock()
    private var _port: UInt16?
    private var serverTask: Task<Void, Never>?
    /// Not private so tests can kill the listener the way iOS does.
    var server: HTTPServer?
    private let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()
    private let probeSingleFlight = SingleFlight<MediaIdentity>()

    public private(set) var port: UInt16? {
        get { lock.withLock { _port } }
        set { lock.withLock { _port = newValue } }
    }

    public init(
        store: MediaStore,
        credentials: CredentialStore,
        session: URLSession = StreamProxy.defaultSession(),
        tuning: Tuning = Tuning()
    ) {
        self.store = store
        self.credentials = credentials
        self.session = session
        self.tuning = tuning
    }
```

After this initializer, paste **verbatim** from the old file: `start()`, `ensureRunning()`, `isServing()`, `serverDidExit(_:)`, `stop()`, `traced(_:_:_:)`, `mp4URL(videoId:versionId:)`, `localURL(kind:videoId:versionId:suffix:)`, `RouteParams`, `mp4Params(of:)` and `upstreamURL(path:versionId:)`. They are unchanged. Then delete the old `upstreamRequest`, `isSuccessful`, `handleMP4`, `prepareMP4WithRecovery`, `writeMP4WithRecovery`, `passthroughMP4`, `partialResponse`, `parseContentRange`, `ParsedContentRange` and `boundedWindow`, and add:

```swift
    // MARK: - MP4

    private func handleMP4(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = mp4Params(of: request) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let key = MediaKey.key(videoId: params.videoId, versionId: params.versionId)
        let rangeHeader = request.headers[.range]

        if let response = finishedFileResponse(key: key, rangeHeader: rangeHeader) {
            return response
        }
        guard let url = upstreamURL(path: "videos/\(params.videoId)/stream", versionId: params.versionId) else {
            return HTTPResponse(statusCode: .badGateway)
        }
        let upstream = UpstreamRequests(url: url, credentials: credentials)

        let resolved: (identity: MediaIdentity, generation: Int?)
        do {
            resolved = try await resolveIdentity(key: key, upstream: upstream)
        } catch {
            DevLog.event(.proxy, "MP4 probe failed -> 502", [
                "video_id": "\(params.videoId)", "err": "\(error)",
            ])
            return HTTPResponse(statusCode: .badGateway)
        }
        let total = resolved.identity.totalByteCount
        guard let window = Self.window(rangeHeader: rangeHeader, total: total) else {
            return unsatisfiable(total: total)
        }
        let reader: ProxyReadSession
        if let generation = resolved.generation {
            await store.beginRead(key: key)
            reader = ProxyReadSession(
                store: store, key: key, identity: resolved.identity, generation: generation,
                window: window, upstream: upstream, session: session, tuning: tuning
            )
        } else {
            DevLog.event(.proxy, "MP4 store unavailable, passing through", ["video_id": "\(params.videoId)"])
            reader = ProxyReadSession(
                passthroughOf: window, key: key, identity: resolved.identity,
                upstream: upstream, session: session, tuning: tuning
            )
        }
        return HTTPResponse(
            statusCode: .partialContent,
            headers: Self.partialHeaders(window, total: total),
            body: HTTPBodySequence(
                from: ProxyBody(reader: reader),
                count: Int(window.length),
                suggestedBufferSize: tuning.readSize
            )
        )
    }

    /// A nil generation means the store could not make room for the entry.
    private func resolveIdentity(
        key: String,
        upstream: UpstreamRequests
    ) async throws -> (identity: MediaIdentity, generation: Int?) {
        if let known = await store.verifiedIdentity(key: key) {
            return (known.identity, known.generation)
        }
        let session = session
        let identity = try await probeSingleFlight.run(key: key) {
            try await IdentityProbe.fetch(upstream.probe(), session: session)
        }
        do {
            return (identity, try await store.open(key: key, identity: identity))
        } catch {
            guard await store.evictForStorageFailure(excluding: key),
                  let generation = try? await store.open(key: key, identity: identity)
            else { return (identity, nil) }
            return (identity, generation)
        }
    }

    private func finishedFileResponse(key: String, rangeHeader: String?) -> HTTPResponse? {
        let url = store.finishedURL(key: key)
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
            .int64Value, size > 0
        else { return nil }
        guard let window = Self.window(rangeHeader: rangeHeader, total: size) else {
            return unsatisfiable(total: size)
        }
        guard let body = try? HTTPBodySequence(
            file: url,
            range: Int(window.start)..<Int(window.end + 1),
            suggestedBufferSize: tuning.readSize
        ) else { return nil }
        return HTTPResponse(statusCode: .partialContent, headers: Self.partialHeaders(window, total: size), body: body)
    }

    private func unsatisfiable(total: Int64) -> HTTPResponse {
        HTTPResponse(statusCode: .rangeNotSatisfiable, headers: [.contentRange: "bytes */\(total)"])
    }

    private static func partialHeaders(_ window: DownloadByteRange, total: Int64) -> HTTPHeaders {
        [
            .contentType: "video/mp4",
            .contentRange: "bytes \(window.start)-\(window.end)/\(total)",
            .acceptRanges: "bytes",
        ]
    }

    /// The requested range clamped to the file, **never capped**: AVPlayer
    /// asks for the whole file and fails the item on anything shorter.
    static func window(rangeHeader: String?, total: Int64) -> DownloadByteRange? {
        let requested = parseRange(rangeHeader, total: total) ?? DownloadByteRange(start: 0, end: total - 1)
        guard requested.start >= 0, requested.start < total else { return nil }
        return DownloadByteRange(start: requested.start, end: min(requested.end, total - 1))
    }

    private static func parseRange(_ header: String?, total: Int64) -> DownloadByteRange? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 {
            return DownloadByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(parts[0]) else { return nil }
        let end = Int64(parts[1]) ?? (total - 1)
        guard end >= start else { return nil }
        return DownloadByteRange(start: start, end: min(end, total - 1))
    }
}
```

Keep the `SingleFlight` actor at the bottom of the file, unchanged. Also update the `traced` route registration in `start()`, which calls `handleMP4`; it needs no change.

- [ ] **Step 5: Wire the app to one store**

In `ios/PatataTube/Sources/AppModel.swift`:

- delete the property `let streamCache: StreamCache`;
- delete `let streamCache = StreamCache()` and `self.streamCache = streamCache` in `init`;
- replace the proxy construction with:

```swift
        self.streamProxy = StreamProxy(
            store: cache.mediaStore,
            credentials: credentials
        )
```

- in `makeCacheStatisticsCollector()`, replace `streamRoot: streamCache.root,` with `streamRoot: cache.mediaStore.storeRoot,`.

- [ ] **Step 6: Point cache statistics at the store**

In `Sources/PatataTubeKit/CacheStatistics.swift`:

- the `proxyBudgetBytes` default becomes `MediaStore.defaultBudgetBytes`;
- in `collect()`, `scanProxyRoot(streamRoot.appendingPathComponent("mp4", isDirectory: true))` becomes `scanProxyRoot(streamRoot)`;
- the `proxy.mp4` row's label becomes `"Streamed & partial downloads"`;
- in `scanVideosRoot()`, first line inside `for entry in entries {`, add `if entry.lastPathComponent == ".store" { continue }` (the store is counted by the proxy row, and the videos root contains it).

In `Tests/PatataTubeKitTests/CacheStatisticsCollectorTests.swift`:

- `try write(stream.appendingPathComponent("mp4/3:9/data.bin"))` becomes `try write(stream.appendingPathComponent("3:9/data.bin"))`;
- `StreamCache.defaultBudgetBytes` becomes `MediaStore.defaultBudgetBytes`;
- add this test to the class:

```swift
    func testTheStoreInsideTheVideosRootIsNotCountedTwice() async throws {
        let videos = makeRoot()
        let lists = makeRoot()
        let tmp = makeRoot()
        defer { [videos, lists, tmp].forEach { try? fileManager.removeItem(at: $0) } }
        try write(videos.appendingPathComponent(".store/3/data.bin"))
        let collector = CacheStatisticsCollector(
            videosRoot: videos,
            streamRoot: videos.appendingPathComponent(".store", isDirectory: true),
            videoListRoot: lists,
            tmpRoot: tmp
        )
        let stats = await collector.collect()
        XCTAssertEqual(stat(stats, "proxy.mp4").byteCount, Int64(blockSize))
        XCTAssertEqual(stat(stats, "other").byteCount, 0)
        XCTAssertEqual(stat(stats, "total").byteCount, Int64(blockSize))
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "StreamProxyTests|CacheStatisticsCollectorTests"`
Expected: all pass. The regression test `testAWholeFileRequestGetsTheWholeFile` is the one that failed on 2.8.

Then build the app:

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS Simulator' build -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/ProxyBody.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheStatistics.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheStatisticsCollectorTests.swift \
        ios/PatataTube/Sources/AppModel.swift
git commit -m "kit: stream the whole requested range through the proxy

AVPlayer asked for the whole file and got an 8 MB 206, then failed the
item: long videos never started. The proxy now answers the full range
as one streamed body from the shared store — committed bytes from disk,
otherwise its own fetcher parked 32 MB ahead.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Delete the old cache code

**Files:**
- Modify: `Sources/PatataTubeKit/ByteRangeSet.swift` (receive `DownloadByteRange`)
- Modify: `Sources/PatataTubeKit/PausedDownloadStore.swift` (doc comment)
- Delete: `RangeStore.swift`, `StreamCache.swift`, `StreamCacheLRU.swift`, `SegmentByteSink.swift`, `SegmentedDownload.swift`
- Delete tests: `RangeStoreTests.swift`, `SegmentedDownloadTests.swift`, `SegmentByteSinkTests.swift`, `StreamCacheTests.swift`, `StreamCacheLRUTests.swift`

- [ ] **Step 1: Move DownloadByteRange**

Append to `Sources/PatataTubeKit/ByteRangeSet.swift`:

```swift
/// An inclusive byte range, as in an HTTP `Range` header.
struct DownloadByteRange: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }
    var headerValue: String { "bytes=\(start)-\(end)" }
}
```

- [ ] **Step 2: Delete the old sources and their tests**

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTubeKit
git rm Sources/PatataTubeKit/RangeStore.swift Sources/PatataTubeKit/StreamCache.swift \
       Sources/PatataTubeKit/StreamCacheLRU.swift Sources/PatataTubeKit/SegmentByteSink.swift \
       Sources/PatataTubeKit/SegmentedDownload.swift \
       Tests/PatataTubeKitTests/RangeStoreTests.swift Tests/PatataTubeKitTests/SegmentedDownloadTests.swift \
       Tests/PatataTubeKitTests/SegmentByteSinkTests.swift Tests/PatataTubeKitTests/StreamCacheTests.swift \
       Tests/PatataTubeKitTests/StreamCacheLRUTests.swift
```

- [ ] **Step 3: Update PausedDownloadStore's doc comment**

Replace the doc comment above `struct PausedDownloadStore` with:

```swift
/// 2.8's paused downloads (`paused-downloads.json`). Read only by
/// `LegacyCacheMigration`, which turns each entry into a paused, pinned
/// `MediaStore` entry and empties the file; it also still records 2.8 HLS
/// pauses for `CacheManager.removeLegacyHLSPackages`.
```

- [ ] **Step 4: Confirm nothing refers to the old types**

Run:

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios
grep -rn "SegmentedDownload\|DownloadProbe\|RangeStore\|StreamCache\b\|StreamCacheLRU\|StreamCacheSeeding\|SegmentByteSink\|validateProbe\|mp4Window" PatataTubeKit/Sources PatataTubeKit/Tests PatataTube/Sources PatataTube/Tests
```

Expected: no output. (`StreamCache\b` must not match `StreamCacheStatistics`-style names. If a doc comment still names an old type, reword it.)

- [ ] **Step 5: Build and run the whole kit suite's cache-related tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MediaStore|DownloadPlanner|LegacyCacheMigration|DataTaskStream|RangeFetcher|DownloadJobRunner|CacheManager|StreamProxy|CacheStatistics|ByteRangeSet|PausedDownloadStore|DownloadActivity"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/ByteRangeSet.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/PausedDownloadStore.swift
git commit -m "kit: delete the range store, stream cache and segmented downloads

Everything they did now lives in MediaStore, RangeFetcher and
DownloadJobRunner.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: AVPlayer smoke test through the real proxy

**Files:**
- Create: `Tests/PatataTubeKitTests/Fixtures/tiny.mp4`
- Modify: `ios/PatataTubeKit/Package.swift` (test resources)
- Test: `Tests/PatataTubeKitTests/AVPlayerSmokeTests.swift`

- [ ] **Step 1: Generate the fixture**

A 3-second 160×120 H.264/AAC faststart mp4, small enough to commit (tens of KB):

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTubeKit && mkdir -p Tests/PatataTubeKitTests/Fixtures && ffmpeg -y -f lavfi -i testsrc=duration=3:size=160x120:rate=15 -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -profile:v baseline -c:a aac -shortest -movflags +faststart Tests/PatataTubeKitTests/Fixtures/tiny.mp4
```

Expected: the file exists. `ls -l Tests/PatataTubeKitTests/Fixtures/tiny.mp4` shows under 200 KB.

- [ ] **Step 2: Declare it as a test resource**

In `Package.swift`, add `resources: [.copy("Fixtures")],` to the `.testTarget(name: "PatataTubeKitTests", …)` arguments, between `dependencies:` and `swiftSettings:`.

- [ ] **Step 3: Write the test**

`Tests/PatataTubeKitTests/AVPlayerSmokeTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import PatataTubeKit

/// Real AVFoundation (macOS shares the iOS HTTP loader) against the real
/// proxy. Small commits make the playback path cross many commit and read
/// boundaries. This is the reproduction that showed the 8 MB cap failing
/// the item.
@MainActor
final class AVPlayerSmokeTests: XCTestCase {
    func testPlaysThroughTheStreamingProxy() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"))
        let body = try Data(contentsOf: fixture)
        MockURLProtocol.stubRanged(path: "/videos/31/stream", fullBody: body, etag: "\"tiny\"")
        defer { MockURLProtocol.reset() }

        let root = temporaryVideosRoot("smoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var tuning = StreamProxy.Tuning()
        tuning.commitSize = 4096
        tuning.readSize = 4096
        tuning.readAhead = 16 * 1024
        tuning.waitWithin = 4096
        let proxy = StreamProxy(
            store: MediaStore(videosRoot: root),
            credentials: InMemoryCredentialStore(baseURL: URL(string: "https://upstream.test"), token: "tok"),
            session: URLSession(configuration: config),
            tuning: tuning
        )
        await proxy.start()

        let player = AVPlayer(url: try XCTUnwrap(proxy.mp4URL(videoId: 31, versionId: nil)))
        player.isMuted = true
        let ready = await poll { player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "item status \(player.currentItem?.status.rawValue ?? -1), error \(String(describing: player.currentItem?.error))")
        player.play()
        let advanced = await poll { player.currentTime().seconds > 0.3 }
        XCTAssertTrue(advanced, "playback never advanced")
        player.pause()
        await proxy.stop()
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
```

- [ ] **Step 4: Run it**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AVPlayerSmokeTests`
Expected: PASS within ~10 s. If it fails with a status/error, debug with the `systematic-debugging` skill before going on. The usual cause is a `Content-Length` that disagrees with the bytes actually sent.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Package.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/Fixtures/tiny.mp4 \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/AVPlayerSmokeTests.swift
git commit -m "kit: AVPlayer smoke test through the streaming proxy

Real AVFoundation reaches readyToPlay and advances on a fixture served
through the proxy with tiny commits and reads.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: App target build and documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Build the app target and its tests (no run)**

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=C0D83EFE-4F6C-4324-8743-6F77259BE12C" build-for-testing -quiet
```

Expected: `** TEST BUILD SUCCEEDED **`. The app-target tests never named the cache internals (checked while planning: `grep -n "PausedDownload\|StreamCache\|CacheManager" ios/PatataTube/Tests/*.swift` finds nothing). If anything there fails to compile, fix the call site to the new public API.

- [ ] **Step 2: Rewrite the downloads paragraph in CLAUDE.md**

In `CLAUDE.md`, replace the whole bullet that starts `- **Downloads can be paused, and a pause outlives the process.**` (it ends before `- **The in-app web bridge has an address bar.**`) with:

```markdown
- **Playback and downloads share one per-video store.** `MediaStore`
  (PatataTubeKit) keeps one entry per cache key under
  `Documents/videos/.store/<key>/`: a sparse `data.bin` plus `entry.json`
  (ETag, size, committed ranges, pin/paused, last access), and in memory the
  **claims** — ranges a fetcher is downloading right now. Claims never
  overlap, so a byte is fetched once even while a video is watched and
  downloaded at the same time. `StreamProxy` answers AVPlayer's **full**
  requested range as one streamed 206 — never a capped window: 2.8 answered
  with 8 MB windows, and AVPlayer failed every longer file. It serves
  committed bytes from disk, waits for a fetcher at most 4 MB behind the
  playhead, or starts its own playback fetcher, which parks 32 MB ahead of
  what was sent (its claim is then *idle*, and a download may take over the
  rest). A download pins the entry and keeps `streamCount` fetchers on the
  holes (`DownloadJobRunner`); **pause** cancels them and keeps the committed
  ranges and the gate permit, **resume** refills the holes, **cancel** unpins
  and deletes once no player response still reads the entry. Whatever closes
  the last hole — a download or watching — renames `data.bin` to
  `videos/<id>.mp4`, so a video watched to the end *is* a download. Unpinned
  partial entries are LRU-evicted under 50 GB; pinned ones and finished mp4s
  never. `CacheManager` keeps only the synchronous UI mirror and sends store
  writes through one serial queue (`settleStoreWork()` waits for it). First
  launch of 2.9 deletes `Caches/stream`, segmented part files and `.resume`
  files, and turns 2.8 paused downloads into paused entries that restart
  from zero once (`LegacyCacheMigration`). Design:
  `docs/superpowers/specs/2026-11-21-streaming-mp4-proxy-design.md`.
```

Also in the `### iOS` section, in the bullet starting `` - `ios/PatataTube/` — the SwiftUI app shell``, replace `` `CacheManager` downloads MP4s for offline playback; `` with `` `CacheManager` downloads MP4s into the shared `MediaStore` for offline playback; ``.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: playback and downloads share one per-video store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Checkpoint: test runs, on-device check, hand-off

No code. This task stops and hands over to the owner.

- [ ] **Step 1: Ask the owner to run (or approve running) the suites**

Per `CLAUDE.md`, ask in chat whether to run these now. If the owner answered "no" in Task 1, this is the first time any of them run. List them, each in its own block:

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTubeKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTubeKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release
```

```bash
cd /Users/grillermo/c/patatatube/.claude/worktrees/streaming-proxy/ios/PatataTube && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination "platform=iOS Simulator,id=C0D83EFE-4F6C-4324-8743-6F77259BE12C" test
```

When reading results, remember `CLAUDE.md`'s known noise: the full parallel `swift test` prints a pre-existing `Fatal error: Index out of range` from swift-testing, and `VideoStoreTests` can flake. Re-run a failing suite filtered before calling it a regression. If any commit was made with "tests compiled, not run", report its outcome now.

- [ ] **Step 2: Hand over the on-device checklist**

The spec says 2.9.0 is done only after this passes on the phone. Give the owner this list (it is theirs to run):

1. A 1-hour video starts at once and seeks (forward, back, near the end).
2. Download a video, then play it immediately: it starts at once.
3. Airplane mode: what was watched still plays; an unwatched part errors within ~10 s instead of hanging.
4. Pause a download, kill the app, relaunch: the row is still paused with its progress; resume finishes it.
5. Background audio keeps playing across a locked screen.
6. AirPlay to the Apple TV works (`airplay_mp4`, unchanged path).
7. A video watched to the end shows as downloaded.

- [ ] **Step 3: Finish the branch**

Use the `finishing-a-development-branch` skill. Do **not** deploy: this is a worktree branch, and per the spec's rollout, 2.9.0 ships through `./deploy` from the release branch only after the on-device check. That unblocks the remove-HLS plan's B6 deploy; its A6 Steps 6–7 wait for 2.9.0 to be confirmed on the phone. Tell the owner in one line that the deploy was skipped and why.
