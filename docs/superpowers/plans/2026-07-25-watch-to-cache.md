# Watch-to-Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture streamed MP4 bytes during iOS playback so a full linear watch of an uncached, direct-MP4 video leaves it fully cached — identical on disk and in the UI to a manual download.

**Architecture:** A new `PatataTubeKit` subsystem plays uncached MP4 videos through an `AVAssetResourceLoaderDelegate` on a private `ptcapture` URL scheme. Each player byte-range request is served from a sparse on-disk file when already captured, else fetched over HTTP (bearer-authed, ETag-checked) and written to the sparse file, tracked in a persisted `CapturedDownloadManifest` of coalesced ranges. On play-to-end, missing ranges are filled ("finalize"), then the completed file is atomically published to the existing cached-MP4 location, flipping `CacheState` to `.cached`. State and progress unify with the existing manual downloader (one owner per cache key).

**Tech Stack:** Swift 6, `PatataTubeKit` SwiftPM package (iOS 17 / macOS 14), AVFoundation (`AVAssetResourceLoaderDelegate`), Foundation `URLSession`, Swift Testing (`import Testing`), `MockURLProtocol`.

## Global Constraints

- Package floor: iOS 17, macOS 14, `swift-tools-version: 6.0` (do not change `Package.swift` platforms/tools version).
- Cache root & layout: reuse `CacheManager.root` (`Documents/videos`) and the existing `.downloads/{cacheKey}/` directory convention from `SegmentedDownloadStore`.
- Cache key format: `"\(videoId)"` or `"\(videoId):\(versionId)"` — identical to `SegmentedDownloadManifest.cacheKey`.
- Published file destination: `CacheManager.localURL(for:versionId:)` (`{videoId}.mp4` or `{videoId}:{versionId}.mp4`).
- Server contract (already implemented, do not change): `GET /videos/{id}/stream[?version_id=]` returns `206` with `Accept-Ranges: bytes`, strong `ETag`, `Content-Range: bytes start-end/total`. A `bytes=0-0` probe returns `Content-Length: 1`.
- Auth: `Authorization: Bearer <token>` on every stream request.
- Strong ETag only (must start & end with `"`); reuse `isValidStrongETag` semantics.
- Memory: never buffer a whole file/segment; copy network→disk and disk→player in ≤1 MiB chunks.
- Tests: Swift Testing (`@Test`, `#expect`), suites `.serialized` when touching shared temp dirs. Run with `swift test` from `ios/PatataTubeKit`.
- Scope: MP4-streamed videos only. HLS videos (`video.hlsPath` non-empty) are never captured.

---

### Task 1: Range algebra — union (coalesce) and complement

Pure interval math on `DownloadByteRange`, the foundation for tracking captured ranges and computing gaps. No AVFoundation, no I/O.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CapturedRanges.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedRangesTests.swift`

**Interfaces:**
- Consumes: `DownloadByteRange` (existing, in `SegmentedDownload.swift`: `struct DownloadByteRange { let start: Int64; let end: Int64; var length: Int64 }`, inclusive bounds).
- Produces:
  - `enum CapturedRanges { static func inserting(_ r: DownloadByteRange, into ranges: [DownloadByteRange]) -> [DownloadByteRange] }` — returns sorted, coalesced, non-overlapping ranges.
  - `static func complement(of ranges: [DownloadByteRange], over total: Int64) -> [DownloadByteRange]` — the uncovered inclusive ranges within `[0, total-1]`.
  - `static func coveredBytes(_ ranges: [DownloadByteRange]) -> Int64`.
  - `static func isComplete(_ ranges: [DownloadByteRange], total: Int64) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
// CapturedRangesTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured range algebra")
struct CapturedRangesTests {
    private func r(_ s: Int64, _ e: Int64) -> DownloadByteRange { .init(start: s, end: e) }

    @Test func insertingMergesOverlapAndAdjacency() {
        var ranges: [DownloadByteRange] = []
        ranges = CapturedRanges.inserting(r(0, 4), into: ranges)
        ranges = CapturedRanges.inserting(r(5, 9), into: ranges)   // adjacent → merge
        #expect(ranges == [r(0, 9)])
        ranges = CapturedRanges.inserting(r(20, 25), into: ranges)
        #expect(ranges == [r(0, 9), r(20, 25)])
        ranges = CapturedRanges.inserting(r(8, 22), into: ranges)  // overlaps both → one span
        #expect(ranges == [r(0, 25)])
    }

    @Test func insertingKeepsSortedAndDedupes() {
        var ranges: [DownloadByteRange] = []
        ranges = CapturedRanges.inserting(r(30, 39), into: ranges)
        ranges = CapturedRanges.inserting(r(0, 9), into: ranges)
        ranges = CapturedRanges.inserting(r(0, 9), into: ranges)   // duplicate
        #expect(ranges == [r(0, 9), r(30, 39)])
    }

    @Test func complementReturnsGaps() {
        let ranges = [r(0, 9), r(20, 29)]
        #expect(CapturedRanges.complement(of: ranges, over: 40) == [r(10, 19), r(30, 39)])
        #expect(CapturedRanges.complement(of: [r(0, 39)], over: 40) == [])
        #expect(CapturedRanges.complement(of: [], over: 40) == [r(0, 39)])
    }

    @Test func coveredBytesAndCompleteness() {
        let ranges = [r(0, 9), r(20, 29)]
        #expect(CapturedRanges.coveredBytes(ranges) == 20)
        #expect(CapturedRanges.isComplete(ranges, total: 40) == false)
        #expect(CapturedRanges.isComplete([r(0, 39)], total: 40) == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedRangesTests`
Expected: FAIL — `cannot find 'CapturedRanges' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// CapturedRanges.swift
import Foundation

/// Interval algebra over inclusive `DownloadByteRange`s used to track which
/// byte ranges of a video have been captured to disk during playback.
enum CapturedRanges {
    /// Insert `range` into a sorted, non-overlapping set, merging any ranges
    /// that overlap or touch (adjacency: `a.end + 1 == b.start`).
    static func inserting(
        _ range: DownloadByteRange,
        into ranges: [DownloadByteRange]
    ) -> [DownloadByteRange] {
        var merged = range
        var result: [DownloadByteRange] = []
        var inserted = false
        for existing in (ranges + [range]).sorted(by: { $0.start < $1.start })
        where existing.start != range.start || existing.end != range.end || !inserted {
            _ = inserted // no-op guard; real merge below
        }
        // Straightforward sweep merge.
        result = []
        merged = ranges.isEmpty ? range : ranges[0]
        let all = (ranges + [range]).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
        merged = all[0]
        for next in all.dropFirst() {
            if next.start <= merged.end + 1 {
                merged = DownloadByteRange(start: merged.start, end: max(merged.end, next.end))
            } else {
                result.append(merged)
                merged = next
            }
        }
        result.append(merged)
        return result
    }

    /// The inclusive ranges within `[0, total-1]` not covered by `ranges`.
    static func complement(
        of ranges: [DownloadByteRange],
        over total: Int64
    ) -> [DownloadByteRange] {
        guard total > 0 else { return [] }
        let sorted = ranges.sorted { $0.start < $1.start }
        var gaps: [DownloadByteRange] = []
        var cursor: Int64 = 0
        for range in sorted {
            if range.start > cursor {
                gaps.append(DownloadByteRange(start: cursor, end: range.start - 1))
            }
            cursor = max(cursor, range.end + 1)
        }
        if cursor < total {
            gaps.append(DownloadByteRange(start: cursor, end: total - 1))
        }
        return gaps
    }

    static func coveredBytes(_ ranges: [DownloadByteRange]) -> Int64 {
        ranges.reduce(0) { $0 + $1.length }
    }

    static func isComplete(_ ranges: [DownloadByteRange], total: Int64) -> Bool {
        total > 0 && coveredBytes(ranges) == total && ranges.count <= 1 == false || (
            ranges.count == 1 && ranges[0].start == 0 && ranges[0].end == total - 1
        )
    }
}
```

> Note: rewrite `inserting` cleanly during Step 3 (the sweep-merge block starting at `result = []` is the real implementation; delete the dead first loop). Rewrite `isComplete` to the simple form: coalesced ranges are complete iff exactly one range spanning `0...total-1`:
> ```swift
> static func isComplete(_ ranges: [DownloadByteRange], total: Int64) -> Bool {
>     ranges.count == 1 && ranges[0].start == 0 && ranges[0].end == total - 1
> }
> ```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedRangesTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CapturedRanges.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedRangesTests.swift
git commit -m "feat(ios): captured-range union and complement algebra"
```

---

### Task 2: CapturedDownloadManifest

The persisted record of a partial capture: total size, entity tag, and the coalesced captured ranges. Codable, with a progress accessor.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadManifestTests.swift`

**Interfaces:**
- Consumes: `DownloadByteRange`, `CapturedRanges` (Task 1).
- Produces:
  - `struct CapturedDownloadManifest: Codable, Equatable, Sendable` with `schemaVersion: Int` (const 1), `videoId: Int`, `versionId: Int?`, `remoteURL: URL`, `totalByteCount: Int64`, `etag: String`, `capturedRanges: [DownloadByteRange]`.
  - `var cacheKey: String` (matches `SegmentedDownloadManifest.cacheKey`).
  - `var progress: Double` (`coveredBytes / totalByteCount`, clamped 0…1).
  - `var isComplete: Bool`.
  - `static func make(videoId:versionId:remoteURL:totalByteCount:etag:) -> CapturedDownloadManifest` (empty ranges).
  - `mutating func capture(_ range: DownloadByteRange)` (coalesces via `CapturedRanges.inserting`).

- [ ] **Step 1: Write the failing test**

```swift
// CapturedDownloadManifestTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured download manifest")
struct CapturedDownloadManifestTests {
    private func manifest() -> CapturedDownloadManifest {
        .make(videoId: 7, versionId: 2,
              remoteURL: URL(string: "https://srv.test/videos/7/stream?version_id=2")!,
              totalByteCount: 100, etag: "\"v7\"")
    }

    @Test func cacheKeyMatchesSegmentedFormat() {
        #expect(manifest().cacheKey == "7:2")
        #expect(CapturedDownloadManifest.make(
            videoId: 7, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/7/stream")!,
            totalByteCount: 100, etag: "\"v7\"").cacheKey == "7")
    }

    @Test func captureCoalescesAndTracksProgress() {
        var m = manifest()
        #expect(m.progress == 0)
        m.capture(.init(start: 0, end: 49))
        m.capture(.init(start: 50, end: 99))
        #expect(m.capturedRanges == [.init(start: 0, end: 99)])
        #expect(m.progress == 1)
        #expect(m.isComplete)
    }

    @Test func codableRoundTrip() throws {
        var m = manifest()
        m.capture(.init(start: 10, end: 40))
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(CapturedDownloadManifest.self, from: data)
        #expect(decoded == m)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedDownloadManifestTests`
Expected: FAIL — `cannot find 'CapturedDownloadManifest' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// CapturedDownload.swift
import Foundation

struct CapturedDownloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL
    let totalByteCount: Int64
    let etag: String
    var capturedRanges: [DownloadByteRange]

    var cacheKey: String { versionId.map { "\(videoId):\($0)" } ?? "\(videoId)" }

    var progress: Double {
        guard totalByteCount > 0 else { return 0 }
        let covered = CapturedRanges.coveredBytes(capturedRanges)
        return min(max(Double(covered) / Double(totalByteCount), 0), 1)
    }

    var isComplete: Bool { CapturedRanges.isComplete(capturedRanges, total: totalByteCount) }

    static func make(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        totalByteCount: Int64,
        etag: String
    ) -> CapturedDownloadManifest {
        CapturedDownloadManifest(
            schemaVersion: currentSchemaVersion,
            videoId: videoId,
            versionId: versionId,
            remoteURL: remoteURL,
            totalByteCount: totalByteCount,
            etag: etag,
            capturedRanges: []
        )
    }

    mutating func capture(_ range: DownloadByteRange) {
        capturedRanges = CapturedRanges.inserting(range, into: capturedRanges)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedDownloadManifestTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadManifestTests.swift
git commit -m "feat(ios): CapturedDownloadManifest with coalescing and progress"
```

---

### Task 3: CapturedDownloadStore — persistence + sparse file I/O

Persists manifests under `.downloads/{cacheKey}/capture.json`, manages the preallocated sparse file `capture.part`, and reads/writes byte ranges at absolute offsets. Mirrors `SegmentedDownloadStore` conventions so existing teardown paths can reach it.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift` (append the store)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadStoreTests.swift`

**Interfaces:**
- Consumes: `CapturedDownloadManifest` (Task 2), `DownloadByteRange`.
- Produces:
  - `struct CapturedDownloadStore: @unchecked Sendable` with `init(root: URL, fileManager: FileManager = .default)`.
  - `func directory(cacheKey: String) -> URL` → `root/.downloads/{cacheKey}` (same dir as segmented; capture files use distinct names).
  - `func manifestURL(cacheKey:) -> URL` → `.../capture.json`
  - `func partURL(cacheKey:) -> URL` → `.../capture.part`
  - `func write(_ manifest:) throws`, `func load(cacheKey:) throws -> CapturedDownloadManifest`, `func manifests() -> [CapturedDownloadManifest]`, `func remove(cacheKey:)`.
  - `func ensureSparseFile(cacheKey:totalByteCount:) throws` — creates `capture.part` sized to `totalByteCount` (truncate/allocate) if absent.
  - `func writeRange(cacheKey:offset:data:) throws` — writes `data` at `offset` in `capture.part`.
  - `func readRange(cacheKey:range:) throws -> Data` — reads an inclusive range from `capture.part`.
  - `func publish(cacheKey:to destination: URL) throws` — atomically moves/replaces `capture.part` to `destination`, then `remove(cacheKey:)`.

- [ ] **Step 1: Write the failing test**

```swift
// CapturedDownloadStoreTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured download store", .serialized)
struct CapturedDownloadStoreTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)")
    }

    @Test func manifestRoundTrips() throws {
        let store = CapturedDownloadStore(root: root())
        var m = CapturedDownloadManifest.make(
            videoId: 3, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/3/stream")!,
            totalByteCount: 10, etag: "\"v3\"")
        m.capture(.init(start: 0, end: 4))
        try store.write(m)
        #expect(try store.load(cacheKey: "3") == m)
        #expect(store.manifests().map(\.cacheKey) == ["3"])
        store.remove(cacheKey: "3")
        #expect(store.manifests().isEmpty)
    }

    @Test func sparseFileWriteReadRoundTrip() throws {
        let store = CapturedDownloadStore(root: root())
        try store.ensureSparseFile(cacheKey: "9", totalByteCount: 8)
        try store.writeRange(cacheKey: "9", offset: 2, data: Data([0xAA, 0xBB]))
        let read = try store.readRange(cacheKey: "9", range: .init(start: 2, end: 3))
        #expect(read == Data([0xAA, 0xBB]))
    }

    @Test func publishMovesCompletedFileAndRemovesManifest() throws {
        let base = root()
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 5, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/5/stream")!,
            totalByteCount: 4, etag: "\"v5\"")
        m.capture(.init(start: 0, end: 3))
        try store.write(m)
        try store.ensureSparseFile(cacheKey: "5", totalByteCount: 4)
        try store.writeRange(cacheKey: "5", offset: 0, data: Data([1, 2, 3, 4]))
        let dest = base.appendingPathComponent("5.mp4")
        try store.publish(cacheKey: "5", to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3, 4]))
        #expect(store.manifests().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedDownloadStoreTests`
Expected: FAIL — `cannot find 'CapturedDownloadStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `CapturedDownload.swift`:

```swift
struct CapturedDownloadStore: @unchecked Sendable {
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    private var downloadsRoot: URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
    }
    func directory(cacheKey: String) -> URL {
        downloadsRoot.appendingPathComponent(cacheKey, isDirectory: true)
    }
    func manifestURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("capture.json")
    }
    func partURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("capture.part")
    }

    func write(_ manifest: CapturedDownloadManifest) throws {
        let dir = directory(cacheKey: manifest.cacheKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(cacheKey: manifest.cacheKey), options: .atomic)
    }

    func load(cacheKey: String) throws -> CapturedDownloadManifest {
        let data = try Data(contentsOf: manifestURL(cacheKey: cacheKey))
        let manifest = try JSONDecoder().decode(CapturedDownloadManifest.self, from: data)
        guard manifest.cacheKey == cacheKey,
              manifest.schemaVersion == CapturedDownloadManifest.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    func manifests() -> [CapturedDownloadManifest] {
        let dirs = (try? fileManager.contentsOfDirectory(
            at: downloadsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? load(cacheKey: $0.lastPathComponent) }
    }

    func remove(cacheKey: String) {
        try? fileManager.removeItem(at: manifestURL(cacheKey: cacheKey))
        try? fileManager.removeItem(at: partURL(cacheKey: cacheKey))
        // Leave the directory if the segmented downloader also uses it.
        try? fileManager.removeItem(at: directory(cacheKey: cacheKey))
    }

    func ensureSparseFile(cacheKey: String, totalByteCount: Int64) throws {
        let dir = directory(cacheKey: cacheKey)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = partURL(cacheKey: cacheKey)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(totalByteCount))
        }
    }

    func writeRange(cacheKey: String, offset: Int64, data: Data) throws {
        let handle = try FileHandle(forWritingTo: partURL(cacheKey: cacheKey))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    func readRange(cacheKey: String, range: DownloadByteRange) throws -> Data {
        let handle = try FileHandle(forReadingFrom: partURL(cacheKey: cacheKey))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.start))
        return try handle.read(upToCount: Int(range.length)) ?? Data()
    }

    func publish(cacheKey: String, to destination: URL) throws {
        let part = partURL(cacheKey: cacheKey)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: destination)
        }
        remove(cacheKey: cacheKey)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CapturedDownloadStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CapturedDownload.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CapturedDownloadStoreTests.swift
git commit -m "feat(ios): CapturedDownloadStore with sparse file I/O and publish"
```

---

### Task 4: RangeFetcher — probe + serve-from-disk-or-network

The testable heart. Given a cache key + remote URL + bearer token, it (a) probes content-info once (total + strong ETag), and (b) serves an inclusive byte range: from the sparse file when already captured, else via an HTTP range GET that is validated, written to disk, recorded in the manifest, and returned. AVFoundation-free; driven by an injectable `URLSession` so `MockURLProtocol` can test it.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherTests.swift`

**Interfaces:**
- Consumes: `CapturedDownloadStore`, `CapturedDownloadManifest`, `DownloadByteRange`, `CapturedRanges`.
- Produces:
  - `struct ContentInfo: Equatable, Sendable { let totalByteCount: Int64; let etag: String }`
  - `enum RangeFetcherError: Error, Equatable { case invalidProbe, changedEntity, badStatus(Int), lengthMismatch }`
  - `actor RangeFetcher` with:
    - `init(cacheKey: String, remoteURL: URL, bearerToken: String?, store: CapturedDownloadStore, session: URLSession, onProgress: @Sendable (Double) -> Void)`
    - `func loadContentInfo() async throws -> ContentInfo` — issues `bytes=0-0`, validates (`206`, `Accept-Ranges: bytes`, strong ETag, `Content-Range: bytes 0-0/total`), memoizes; creates/updates the manifest + sparse file; if a persisted manifest's etag differs, discards it and starts fresh.
    - `func data(for range: DownloadByteRange) async throws -> Data` — returns bytes for the inclusive range, serving captured sub-ranges from disk and fetching the rest.
    - `var manifestSnapshot: CapturedDownloadManifest? { get }`

- [ ] **Step 1: Write the failing test**

```swift
// RangeFetcherTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher", .serialized)
struct RangeFetcherTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fetcher-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })  // 100 bytes 0x00..0x63
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    /// Serves 206 range responses over `body` with a fixed strong ETag.
    private func installHandler(etag: String = "\"v1\"", failGET: Bool = false) {
        let body = body
        MockURLProtocol.handler = { request in
            let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0"
            let spec = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-")
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            if failGET && !(start == 0 && end == 0) { throw URLError(.networkConnectionLost) }
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "ETag": etag,
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    @Test func loadContentInfoParsesTotalAndEtag() async throws {
        installHandler()
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            store: CapturedDownloadStore(root: root()), session: mockSession(),
            onProgress: { _ in })
        let info = try await fetcher.loadContentInfo()
        #expect(info == ContentInfo(totalByteCount: 100, etag: "\"v1\""))
    }

    @Test func dataFetchesWritesAndServesFromDisk() async throws {
        installHandler()
        let store = CapturedDownloadStore(root: root())
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        let first = try await fetcher.data(for: .init(start: 10, end: 19))
        #expect(first == body.subdata(in: 10..<20))
        // Now captured on disk; a second read of a subrange returns identical bytes.
        let again = try await fetcher.data(for: .init(start: 12, end: 15))
        #expect(again == body.subdata(in: 12..<16))
        #expect(await fetcher.manifestSnapshot?.capturedRanges == [.init(start: 10, end: 19)])
    }

    @Test func changedEtagOnFetchThrows() async throws {
        installHandler()
        let store = CapturedDownloadStore(root: root())
        let fetcher = RangeFetcher(
            cacheKey: "1", remoteURL: remote, bearerToken: "t",
            store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        installHandler(etag: "\"v2\"")   // server re-encoded
        await #expect(throws: RangeFetcherError.changedEntity) {
            _ = try await fetcher.data(for: .init(start: 0, end: 9))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherTests`
Expected: FAIL — `cannot find 'RangeFetcher' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// RangeFetcher.swift
import Foundation

struct ContentInfo: Equatable, Sendable {
    let totalByteCount: Int64
    let etag: String
}

enum RangeFetcherError: Error, Equatable {
    case invalidProbe
    case changedEntity
    case badStatus(Int)
    case lengthMismatch
}

/// Serves inclusive byte ranges of a remote MP4, capturing every fetched byte
/// to a sparse file tracked by a `CapturedDownloadManifest`. One instance per
/// playing video; serialized via `actor`.
actor RangeFetcher {
    let cacheKey: String
    let remoteURL: URL
    let bearerToken: String?
    private let store: CapturedDownloadStore
    private let session: URLSession
    private let onProgress: @Sendable (Double) -> Void
    private var manifest: CapturedDownloadManifest?

    init(
        cacheKey: String,
        remoteURL: URL,
        bearerToken: String?,
        store: CapturedDownloadStore,
        session: URLSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.cacheKey = cacheKey
        self.remoteURL = remoteURL
        self.bearerToken = bearerToken
        self.store = store
        self.session = session
        self.onProgress = onProgress
    }

    var manifestSnapshot: CapturedDownloadManifest? { manifest }

    private func authedRequest(range: String) -> URLRequest {
        var request = URLRequest(url: remoteURL)
        request.setValue(range, forHTTPHeaderField: "Range")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func loadContentInfo() async throws -> ContentInfo {
        if let manifest { return ContentInfo(totalByteCount: manifest.totalByteCount, etag: manifest.etag) }

        let (data, response) = try await session.data(for: authedRequest(range: "bytes=0-0"))
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              let etag = http.value(forHTTPHeaderField: "ETag"), isStrongETag(etag),
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0, data.count == 1
        else { throw RangeFetcherError.invalidProbe }

        // Resume an existing partial only if the entity is unchanged.
        var loaded = (try? store.load(cacheKey: cacheKey))
        if let existing = loaded, existing.etag != etag {
            store.remove(cacheKey: cacheKey)
            loaded = nil
        }
        var m = loaded ?? CapturedDownloadManifest.make(
            videoId: 0, versionId: nil, remoteURL: remoteURL,
            totalByteCount: total, etag: etag)  // videoId/versionId patched by caller-side store key; see note
        m = fixIdentity(m, total: total, etag: etag)
        try store.ensureSparseFile(cacheKey: cacheKey, totalByteCount: total)
        try store.write(m)
        manifest = m
        onProgress(m.progress)
        return ContentInfo(totalByteCount: total, etag: etag)
    }

    func data(for range: DownloadByteRange) async throws -> Data {
        guard var m = manifest else {
            _ = try await loadContentInfo()
            return try await data(for: range)
        }
        // Fully captured already → serve from disk.
        if CapturedRanges.complement(of: m.capturedRanges, over: m.totalByteCount)
            .allSatisfy({ $0.end < range.start || $0.start > range.end }) {
            return try store.readRange(cacheKey: cacheKey, range: range)
        }
        // Fetch the requested range from the network (simple whole-range fetch;
        // overlaps with existing captured bytes are harmless — same content).
        let (data, response) = try await session.data(for: authedRequest(range: range.headerValue))
        guard let http = response as? HTTPURLResponse else { throw RangeFetcherError.invalidProbe }
        if (400..<600).contains(http.statusCode) { throw RangeFetcherError.badStatus(http.statusCode) }
        guard http.statusCode == 206 else { throw RangeFetcherError.invalidProbe }
        guard http.value(forHTTPHeaderField: "ETag") == m.etag else { throw RangeFetcherError.changedEntity }
        guard Int64(data.count) == range.length else { throw RangeFetcherError.lengthMismatch }

        try store.writeRange(cacheKey: cacheKey, offset: range.start, data: data)
        m.capture(range)
        try store.write(m)
        manifest = m
        onProgress(m.progress)
        return data
    }
}

/// Strong ETag: quoted, not weak (`W/`-prefixed).
func isStrongETag(_ value: String) -> Bool {
    value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
}
```

> Note on identity: `CapturedDownloadManifest` needs the real `videoId`/`versionId` so `manifests()` reload after relaunch maps to the right video. Pass them into `RangeFetcher.init` instead of the placeholder. Update the initializer to accept `videoId: Int, versionId: Int?` and build the manifest with them; delete the `fixIdentity` helper (it was a scaffold). Update the test constructor calls to pass `videoId: 1, versionId: nil`. Make this change in Step 3 before running tests.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherTests.swift
git commit -m "feat(ios): RangeFetcher probes, serves, and captures byte ranges"
```

---

### Task 5: Finalize — fill gaps and publish

Given a `RangeFetcher` that has been playing, fetch every uncaptured range, then publish the completed sparse file to the destination MP4. This is the "played to end → fully downloaded" completion.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift` (add `finalize`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFinalizeTests.swift`

**Interfaces:**
- Consumes: `RangeFetcher` (Task 4), `CapturedDownloadStore.publish`.
- Produces:
  - `func finalize(destination: URL) async throws` on `RangeFetcher` — fetches `CapturedRanges.complement(...)` (in ≤4 MiB sub-chunks), then, once `manifest.isComplete`, calls `store.publish(cacheKey:to:)`. If already complete, publishes immediately. On any fetch failure, leaves the partial intact and rethrows (no publish).

- [ ] **Step 1: Write the failing test**

```swift
// RangeFetcherFinalizeTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Range fetcher finalize", .serialized)
struct RangeFetcherFinalizeTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-\(UUID().uuidString)")
    }
    private let body = Data((0..<100).map { UInt8($0) })
    private let remote = URL(string: "https://srv.test/videos/1/stream")!

    private func installHandler(etag: String = "\"v1\"") {
        let body = body
        MockURLProtocol.handler = { request in
            let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0")
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts[0])!
            let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! : body.count - 1
            let slice = body.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes", "ETag": etag,
                    "Content-Range": "bytes \(start)-\(end)/\(body.count)",
                    "Content-Length": "\(slice.count)",
                ])!
            return (response, slice)
        }
    }

    @Test func finalizeFillsGapsAndPublishesCompleteFile() async throws {
        installHandler()
        let base = root()
        let store = CapturedDownloadStore(root: base)
        let fetcher = RangeFetcher(
            videoId: 1, versionId: nil, cacheKey: "1", remoteURL: remote,
            bearerToken: "t", store: store, session: mockSession(), onProgress: { _ in })
        _ = try await fetcher.loadContentInfo()
        _ = try await fetcher.data(for: .init(start: 0, end: 9))   // watch the head only
        let dest = base.appendingPathComponent("1.mp4")
        try await fetcher.finalize(destination: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == body)
        #expect(store.manifests().isEmpty)   // manifest removed on publish
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherFinalizeTests`
Expected: FAIL — `value of type 'RangeFetcher' has no member 'finalize'` (and the `videoId:` initializer label from Task 4's note).

- [ ] **Step 3: Write minimal implementation**

Add to `RangeFetcher`:

```swift
    /// Fetch every uncaptured range, then publish the completed file. Leaves the
    /// partial intact and rethrows on any failure (never publishes a partial).
    func finalize(destination: URL) async throws {
        guard let m0 = manifest else { _ = try await loadContentInfo(); return try await finalize(destination: destination) }
        let chunk: Int64 = 4 * 1_048_576
        for gap in CapturedRanges.complement(of: m0.capturedRanges, over: m0.totalByteCount) {
            var start = gap.start
            while start <= gap.end {
                let end = min(start + chunk - 1, gap.end)
                _ = try await data(for: DownloadByteRange(start: start, end: end))
                start = end + 1
            }
        }
        guard let m = manifest, m.isComplete else { throw RangeFetcherError.lengthMismatch }
        try store.publish(cacheKey: cacheKey, to: destination)
        manifest = nil
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter RangeFetcherFinalizeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/RangeFetcher.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeFetcherFinalizeTests.swift
git commit -m "feat(ios): finalize fills capture gaps and publishes cached MP4"
```

---

### Task 6: CaptureManager — orchestration + AVAssetResourceLoaderDelegate

Owns per-video `RangeFetcher`s, builds the capturing `AVURLAsset`, and adapts AVFoundation loading requests to `RangeFetcher`. The delegate glue is not unit-testable (constructing `AVAssetResourceLoadingRequest` is impractical); verify via the manual checklist. The `resolvedURL`/`schemeSwap` helpers ARE unit-tested.

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CaptureManagerSchemeTests.swift`

**Interfaces:**
- Consumes: `RangeFetcher`, `CapturedDownloadStore`, `CacheManager.root` / `localURL`.
- Produces:
  - `public final class CaptureManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable`
  - `static let scheme = "ptcapture"`
  - `static func captureURL(from remote: URL) -> URL?` — swaps the scheme to `ptcapture`.
  - `static func remoteURL(from captureURL: URL) -> URL?` — swaps back to `https`.
  - `func asset(videoId:versionId:remoteURL:bearerToken:onProgress:) -> AVURLAsset` — builds the asset, wires the delegate, registers a `RangeFetcher`.
  - `func fetcher(forCacheKey:) -> RangeFetcher?` — for the view's finalize hook.

- [ ] **Step 1: Write the failing test**

```swift
// CaptureManagerSchemeTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Capture manager scheme swap")
struct CaptureManagerSchemeTests {
    @Test func swapsSchemeToPrivateAndBack() throws {
        let remote = URL(string: "https://srv.test/videos/7/stream?version_id=3")!
        let capture = try #require(CaptureManager.captureURL(from: remote))
        #expect(capture.scheme == "ptcapture")
        #expect(capture.absoluteString == "ptcapture://srv.test/videos/7/stream?version_id=3")
        let back = try #require(CaptureManager.remoteURL(from: capture))
        #expect(back == remote)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CaptureManagerSchemeTests`
Expected: FAIL — `cannot find 'CaptureManager' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// CaptureManager.swift
import Foundation
import AVFoundation

public final class CaptureManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "ptcapture"

    private let store: CapturedDownloadStore
    private let session: URLSession
    private let destinationForKey: @Sendable (String) -> URL
    private let delegateQueue = DispatchQueue(label: "patatatube.capture.loader")
    private let lock = NSLock()
    private var fetchers: [String: RangeFetcher] = [:]

    public init(
        store: CapturedDownloadStore,
        session: URLSession = .shared,
        destinationForKey: @escaping @Sendable (String) -> URL
    ) {
        self.store = store
        self.session = session
        self.destinationForKey = destinationForKey
    }

    public static func captureURL(from remote: URL) -> URL? {
        guard var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        return comps.url
    }

    public static func remoteURL(from captureURL: URL) -> URL? {
        guard var comps = URLComponents(url: captureURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "https"
        return comps.url
    }

    public func fetcher(forCacheKey key: String) -> RangeFetcher? {
        lock.withLock { fetchers[key] }
    }

    public func asset(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        bearerToken: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> AVURLAsset {
        let key = versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
        let fetcher = RangeFetcher(
            videoId: videoId, versionId: versionId, cacheKey: key,
            remoteURL: remoteURL, bearerToken: bearerToken,
            store: store, session: session, onProgress: onProgress)
        lock.withLock { fetchers[key] = fetcher }
        let captureURL = Self.captureURL(from: remoteURL) ?? remoteURL
        let asset = AVURLAsset(url: captureURL)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              let remote = Self.remoteURL(from: url) else { return false }
        let key = cacheKey(forRemote: remote)
        guard let fetcher = fetcher(forCacheKey: key) else { return false }

        Task {
            do {
                let info = try await fetcher.loadContentInfo()
                if let infoRequest = loadingRequest.contentInformationRequest {
                    infoRequest.contentType = "public.mpeg-4"
                    infoRequest.contentLength = info.totalByteCount
                    infoRequest.isByteRangeAccessSupported = true
                }
                if let dataRequest = loadingRequest.dataRequest {
                    let start = dataRequest.requestedOffset
                    let wantsAll = dataRequest.requestsAllDataToEndOfResource
                    let end = wantsAll
                        ? info.totalByteCount - 1
                        : min(start + Int64(dataRequest.requestedLength) - 1, info.totalByteCount - 1)
                    let data = try await fetcher.data(
                        for: DownloadByteRange(start: start, end: end))
                    dataRequest.respond(with: data)
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Best-effort; the Task above observes cancellation via finishLoading errors.
    }

    private func cacheKey(forRemote remote: URL) -> String {
        // The fetcher registry is keyed on video id; look it up by matching remoteURL.
        lock.withLock {
            fetchers.first(where: { _, f in f.remoteURLValue == remote })?.key ?? ""
        }
    }
}
```

> Note: `RangeFetcher` needs a non-isolated `remoteURLValue` for the registry lookup. Add `nonisolated let remoteURLValue: URL` set in `init` (mirror `remoteURL`). Simpler alternative implemented here: key the delegate lookup by embedding the cache key in the capture URL path is overkill; instead store `fetchers` keyed by the capture URL's `absoluteString` too. To keep it minimal, add a second dictionary `fetchersByRemote: [URL: String]` updated in `asset(...)`, and have `cacheKey(forRemote:)` read it. Implement whichever is cleaner during Step 3; the unit test only covers scheme swap.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CaptureManagerSchemeTests`
Expected: PASS. Also run full `swift build` to confirm the delegate compiles: `swift build`.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CaptureManager.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CaptureManagerSchemeTests.swift
git commit -m "feat(ios): CaptureManager builds capturing asset via resource loader"
```

---

### Task 7: CacheManager integration — unified state, dedup, teardown

Wire capture into `CacheManager` so the grid/state and cleanup treat a capture partial like a download, with one owner per cache key.

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerCaptureStateTests.swift`

**Interfaces:**
- Consumes: `CapturedDownloadStore`, `CaptureManager`, `CacheState`.
- Produces (public API on `CacheManager`):
  - `func captureAsset(videoId:versionId:remoteURL:bearerToken:) -> AVURLAsset` — delegates to an internally-held `CaptureManager`, wiring `onProgress` to update `inFlight`/publish notifications, but only claims the key when no manual download owns it.
  - `func finalizeCapture(videoId:versionId:) async` — looks up the fetcher, calls `finalize(destination: localURL(...))`, best-effort.
  - `state(for:versionId:)` extended: cached file → `.cached`; else `inFlight[key]` → `.downloading`; else a persisted capture manifest → `.downloading(manifest.progress)`; else `.notCached`.
  - `clearAllVideos`, `removeAllCached(id:)`, `removeCached(id:versionId:)` extended to remove capture manifests/parts via `CapturedDownloadStore`.

- [ ] **Step 1: Write the failing test**

```swift
// CacheManagerCaptureStateTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("CacheManager capture state", .serialized)
struct CacheManagerCaptureStateTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmcapture-\(UUID().uuidString)")
    }

    @Test func persistedPartialReportsDownloadingProgress() throws {
        let base = root()
        let manager = CacheManager(root: base, configuration: .ephemeral)
        // Write a half-complete capture manifest directly via the store.
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 42, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/42/stream")!,
            totalByteCount: 100, etag: "\"v42\"")
        m.capture(.init(start: 0, end: 49))
        try store.write(m)
        if case let .downloading(progress) = manager.state(for: 42) {
            #expect(abs(progress - 0.5) < 0.001)
        } else {
            Issue.record("expected .downloading, got \(manager.state(for: 42))")
        }
    }

    @Test func removeAllCachedClearsCapturePartial() throws {
        let base = root()
        let manager = CacheManager(root: base, configuration: .ephemeral)
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 43, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/43/stream")!,
            totalByteCount: 100, etag: "\"v43\"")
        m.capture(.init(start: 0, end: 9))
        try store.write(m)
        manager.removeAllCached(id: 43)
        #expect(manager.state(for: 43) == .notCached)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerCaptureStateTests`
Expected: FAIL — `state(for:)` returns `.notCached` (capture branch not yet added).

- [ ] **Step 3: Write minimal implementation**

In `CacheManager`:

1. Add a stored `private let capturedStore: CapturedDownloadStore` initialized in `init` with `root: self.root, fileManager: fileManager` (alongside `segmentedStore`).
2. Extend `state(for:versionId:)`:

```swift
public func state(for id: Int, versionId: Int? = nil) -> CacheState {
    let key = cacheKey(videoId: id, versionId: versionId)
    if fileManager.fileExists(atPath: localURL(for: id, versionId: versionId).path) { return .cached }
    return lock.withLock {
        if let accumulator = inFlight[key] { return .downloading(accumulator.activity.progress) }
        if let manifest = try? capturedStore.load(cacheKey: key) {
            return .downloading(manifest.progress)
        }
        return .notCached
    }
}
```

3. In `removeAllCached(id:)`, after removing segment manifests, remove capture partials:

```swift
for manifest in capturedStore.manifests() where manifest.videoId == id {
    capturedStore.remove(cacheKey: manifest.cacheKey)
}
```

4. In `removeCached(id:versionId:)`, add `capturedStore.remove(cacheKey: cacheKey(videoId: id, versionId: versionId))`.
5. In `clearAllVideos()`, after clearing segments, add `for m in capturedStore.manifests() { capturedStore.remove(cacheKey: m.cacheKey) }`.
6. Add the capture entry points (dedup: only claim when no manual download owns the key):

```swift
private lazy var captureManager = CaptureManager(
    store: capturedStore,
    session: session,
    destinationForKey: { [weak self] key in
        self?.localURL(for: self!.videoId(from: key), versionId: self!.versionId(from: key))
            ?? URL(fileURLWithPath: "/dev/null")
    })

public func captureAsset(
    videoId: Int, versionId: Int? = nil, remoteURL: URL, bearerToken: String?
) -> AVURLAsset {
    let key = cacheKey(videoId: videoId, versionId: versionId)
    return captureManager.asset(
        videoId: videoId, versionId: versionId, remoteURL: remoteURL, bearerToken: bearerToken,
        onProgress: { [weak self] progress in
            self?.registerCaptureProgress(key: key, videoId: videoId, versionId: versionId, progress: progress)
        })
}

private func registerCaptureProgress(key: String, videoId: Int, versionId: Int?, progress: Double) {
    lock.withLock {
        // Do not claim the key if a manual download already owns it.
        guard tasksByKey[key] == nil, segmentedAttempts[key] == nil else { return }
        if inFlight[key] == nil {
            inFlight[key] = DownloadActivityAccumulator(
                videoID: videoId, versionID: versionId, totalByteCount: nil, now: now())
        }
        inFlight[key]?.overrideProgress(progress)
    }
}

public func finalizeCapture(videoId: Int, versionId: Int? = nil) async {
    let key = cacheKey(videoId: videoId, versionId: versionId)
    guard let fetcher = captureManager.fetcher(forCacheKey: key) else { return }
    let destination = localURL(for: videoId, versionId: versionId)
    try? await fetcher.finalize(destination: destination)
    lock.withLock { inFlight[key] = nil }
}
```

7. `DownloadActivityAccumulator` needs `mutating func overrideProgress(_:)` (or reuse an existing setter). Inspect `DownloadActivity.swift`; if no direct progress setter exists, add one that stamps a synthetic progress value used by `activity.progress`. Keep it minimal and covered by the existing accumulator tests staying green.
8. `import AVFoundation` at the top of `CacheManager.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerCaptureStateTests`
Then the full suite to catch regressions: `swift test`
Expected: new tests PASS; all existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerCaptureStateTests.swift
git commit -m "feat(ios): unify capture partials into CacheState and teardown"
```

---

### Task 8: VideoPlayerView wiring — play via capture + finalize on end

Route uncached direct-MP4 playback through the capturing asset, and trigger finalize on play-to-end. No unit tests (SwiftUI/AVKit view); verify with the manual checklist in `ios/README.md`.

**Files:**
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift`
- Modify (docs): `ios/README.md` (add manual test steps)

**Interfaces:**
- Consumes: `model.cache.captureAsset(...)`, `model.cache.finalizeCapture(...)`, `model.streamURL(for:)`, `model.credentials.token`, `video.chosenVersionId`, `video.hlsPath`.

- [ ] **Step 1: Change the direct-MP4 branch in `playerItem(for:)`**

Replace the final fallback branch (currently `AVPlayerItem(asset: authedAsset(url: url))`) so an uncached video with a direct MP4 stream (and no HLS) plays through capture:

```swift
if let url = model.streamURL(for: video) {
    // Direct MP4 (no HLS package): play through the capturing asset so a full
    // watch also downloads the file. Falls back to a plain authed asset if a
    // capture URL can't be formed.
    let asset = model.cache.captureAsset(
        videoId: video.id,
        versionId: video.chosenVersionId,
        remoteURL: url,
        bearerToken: model.credentials.token)
    return AVPlayerItem(asset: asset)
}
return nil
```

(The `hlsURL` branch above it is unchanged, so HLS videos never reach this.)

- [ ] **Step 2: Trigger finalize on play-to-end**

In `bindPlayToEnd`, before/after the existing `switch playbackEndAction(...)`, kick off finalize for the item that just ended (only meaningful for capturing items; `finalizeCapture` no-ops when there's no fetcher):

```swift
Task { @MainActor in
    let finished = video   // the item that reached end
    if !finished.isLibrary, finished.hlsPath?.isEmpty ?? true {
        Task { await model.cache.finalizeCapture(
            videoId: finished.id, versionId: finished.chosenVersionId) }
    }
    switch playbackEndAction(
        autoplay: model.autoplay,
        isForeground: UIApplication.shared.applicationState == .active,
        sleepMode: sleepAfterCurrent
    ) {
    case .advance: advance(by: 1)
    case .dismiss: dismiss()
    case .stop: player?.pause()
    case .sleep: player?.pause(); runBlackScreenShortcut()
    }
}
```

> Capture `finished = video` before any `advance` mutates `currentIndex`. The finalize `Task` is detached so advancing to the next item does not cancel it.

- [ ] **Step 3: Build the app target**

Run: `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (If `xcodebuild` is unavailable in the environment, at minimum `cd ios/PatataTubeKit && swift build` must succeed; note the app build as a manual step.)

- [ ] **Step 4: Add manual test steps to `ios/README.md`**

Under the manual checklist, add:

```markdown
### Watch-to-cache (direct-MP4 videos)
1. Ensure a Twitter/YouTube video is NOT cached (grid ring empty).
2. Play it start-to-finish without seeking. Let it reach the end.
3. Return to the grid: the video shows a full ring / cached badge.
4. Enable Airplane Mode, reopen the video: it plays offline from the cached file.
5. Repeat but CLOSE at ~50%: the grid ring shows a partial. Reopen and play to
   the end: it completes to cached.
6. Confirm an HLS library movie does NOT auto-cache from watching (out of scope).
```

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources/VideoPlayerView.swift ios/README.md
git commit -m "feat(ios): play uncached MP4 via capture and finalize on end"
```

---

## Self-Review Notes

- **Spec §1 (trigger point):** Task 8 Step 1 — only the direct-MP4 branch changes; HLS branch untouched. ✓
- **Spec §2 (CaptureManager + resource loader):** Tasks 4 (fetcher core), 6 (delegate + asset). Memory: ≤4 MiB chunks in finalize, single-range reads served from disk. ✓
- **Spec §3 (manifest + resumable partial):** Tasks 2, 3; resume-if-etag-matches in Task 4 `loadContentInfo`. ✓
- **Spec §4 (gap-fill on play-to-end):** Task 5 `finalize`, Task 8 Step 2 hook; detached Task so advancing doesn't cancel. ✓
- **Spec §5 (unified state + dedup):** Task 7 — `state(for:)` capture branch, `registerCaptureProgress` refuses the key when a manual download owns it. ✓ (Manual-download-takeover path: existing `download()` claims `inFlight[key]`/`tasksByKey[key]` first, so capture's `registerCaptureProgress` yields; captured bytes on disk are a best-effort head start — acceptable per spec.)
- **Spec §6 (edge cases):** ETag mismatch → `RangeFetcherError.changedEntity` (Task 4) and discard-on-etag-change in `loadContentInfo`; seek/skip → gaps filled by finalize; no-ETag/probe-fail → delegate returns false / caller falls back (Task 8 fallback `return nil` path — see note below); disk failure → throws, partial intact. ✓
- **Type consistency:** `cacheKey` format, `DownloadByteRange` inclusive bounds, `CapturedDownloadManifest` fields, and `RangeFetcher(videoId:versionId:cacheKey:...)` initializer are consistent across Tasks 4–7. ✓
- **Known follow-ups (documented limitations, not gaps):** (a) A pending finalize is not auto-resumed after app relaunch (spec §6 "documented limitation") — the partial simply waits for the next watch. (b) If the probe fails (no strong ETag), the resource loader returns `false`; ensure a graceful fallback by having `captureAsset` callers tolerate a failed load — acceptable for v1 since the target server always emits strong ETags. If a non-conforming server is a real risk, add a Task 8 fallback that catches the failed asset and rebuilds a plain `authedAsset`.
```
