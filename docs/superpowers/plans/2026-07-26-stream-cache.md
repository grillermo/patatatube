# Stream Read-Through Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AVPlayer streams through a local read-through caching proxy; the download manager reuses already-streamed bytes (HLS segments / MP4 ranges) and fetches only what's missing; HLS gets a full offline story.

**Architecture:** A FlyingFox HTTP server (`StreamProxy`) bound to 127.0.0.1 intercepts all playback. HLS caches per-segment (`SegmentCache`, keyed by a hash of the media playlist); direct MP4s cache per-byte-range in a sparse file (`RangeStore` + `ByteRangeSet`). A 10 GB LRU (`StreamCacheLRU`) evicts whole-video temp entries. Downloads complete the cached set and promote it to permanent storage.

**Tech Stack:** Swift 6 / SwiftPM, FlyingFox (new dependency), AVFoundation, existing `SegmentedDownload` machinery.

**Spec:** `docs/superpowers/specs/2026-07-26-stream-cache-design.md`

## Global Constraints

- Package platform floors stay `.iOS(.v17), .macOS(.v14)`; swift-tools-version 6.0.
- All new logic lives in `ios/PatataTubeKit/Sources/PatataTubeKit/`; app shell only wires it up.
- Test command: `cd ios/PatataTubeKit && swift test` (run from repo root paths below).
- Stream cache budget: **10 GB** (`10 * 1024 * 1024 * 1024` bytes), temp entries only.
- MP4 proxy responses capped at an **8 MB window** per 206 response (bounded memory; the client follows up with the next range).
- Playback must never block on cache failures — always fall back to pass-through/direct.
- Proxy binds loopback only; every route is prefixed with a per-launch random `{secret}` path component.
- No server (Python) changes.
- Commit after every green test cycle. Conventional commit messages, end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `docs/` is gitignored in this repo — never try to commit the plan/spec themselves.

---

### Task 1: FlyingFox dependency

**Files:**
- Modify: `ios/PatataTubeKit/Package.swift`

**Interfaces:**
- Produces: `import FlyingFox` available to kit sources and tests.

- [ ] **Step 1: Baseline** — Run: `cd ios/PatataTubeKit && swift test`. Expected: PASS (record any pre-existing failures; do not fix them).

- [ ] **Step 2: Add dependency**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PatataTubeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PatataTubeKit", targets: ["PatataTubeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.20.0")),
    ],
    targets: [
        .target(
            name: "PatataTubeKit",
            dependencies: [.product(name: "FlyingFox", package: "FlyingFox")]
        ),
        .testTarget(name: "PatataTubeKitTests", dependencies: ["PatataTubeKit"]),
    ]
)
```

If 0.20.0 does not resolve, run `git ls-remote --tags https://github.com/swhitty/FlyingFox.git | tail -5` and use the latest stable tag.

- [ ] **Step 3: Verify** — Run: `cd ios/PatataTubeKit && swift build`. Expected: builds, FlyingFox fetched.

- [ ] **Step 4: Commit** — `git add ios/PatataTubeKit/Package.swift ios/PatataTubeKit/Package.resolved && git commit -m "feat(ios): add FlyingFox dependency for stream proxy"`

---

### Task 2: ByteRangeSet

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ByteRangeSet.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ByteRangeSetTests.swift`

**Interfaces:**
- Consumes: `DownloadByteRange` (internal struct in `SegmentedDownload.swift`: `start: Int64`, `end: Int64` inclusive, `length: Int64`).
- Produces:
  - `struct ByteRangeSet: Codable, Equatable, Sendable`
  - `mutating func insert(_ range: DownloadByteRange)`
  - `func contains(_ range: DownloadByteRange) -> Bool`
  - `func missingRanges(in range: DownloadByteRange) -> [DownloadByteRange]`
  - `func prefixLength(from start: Int64, limit: Int64) -> Int64`
  - `var runs: [DownloadByteRange] { get }` (sorted, disjoint, non-adjacent)
  - `var totalBytes: Int64`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class ByteRangeSetTests: XCTestCase {
    private func r(_ start: Int64, _ end: Int64) -> DownloadByteRange {
        DownloadByteRange(start: start, end: end)
    }

    func testInsertMergesOverlappingAndAdjacentRuns() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        set.insert(r(20, 29))
        set.insert(r(10, 19)) // adjacent to both → single run
        XCTAssertEqual(set.runs, [r(0, 29)])
        XCTAssertEqual(set.totalBytes, 30)
    }

    func testInsertKeepsDisjointRunsSorted() {
        var set = ByteRangeSet()
        set.insert(r(50, 59))
        set.insert(r(0, 9))
        XCTAssertEqual(set.runs, [r(0, 9), r(50, 59)])
    }

    func testContains() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        XCTAssertTrue(set.contains(r(2, 8)))
        XCTAssertFalse(set.contains(r(5, 12)))
    }

    func testMissingRanges() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        set.insert(r(50, 59))
        XCTAssertEqual(set.missingRanges(in: r(0, 99)), [r(10, 49), r(60, 99)])
        XCTAssertEqual(set.missingRanges(in: r(0, 9)), [])
        XCTAssertEqual(set.missingRanges(in: r(100, 199)), [r(100, 199)])
    }

    func testPrefixLength() {
        var set = ByteRangeSet()
        set.insert(r(10, 39))
        XCTAssertEqual(set.prefixLength(from: 10, limit: 100), 30)
        XCTAssertEqual(set.prefixLength(from: 15, limit: 10), 10) // capped by limit
        XCTAssertEqual(set.prefixLength(from: 0, limit: 100), 0)  // hole at start
    }

    func testCodableRoundTrip() throws {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(ByteRangeSet.self, from: data)
        XCTAssertEqual(decoded, set)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd ios/PatataTubeKit && swift test --filter ByteRangeSetTests`. Expected: compile error "cannot find 'ByteRangeSet'".

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Sorted, disjoint, non-adjacent set of inclusive byte runs. The unit of
/// truth for which parts of a remote MP4 exist locally.
struct ByteRangeSet: Codable, Equatable, Sendable {
    private(set) var runs: [DownloadByteRange] = []

    var totalBytes: Int64 { runs.reduce(0) { $0 + $1.length } }

    mutating func insert(_ range: DownloadByteRange) {
        var merged = range
        var kept: [DownloadByteRange] = []
        for run in runs {
            if run.end + 1 < merged.start || merged.end + 1 < run.start {
                kept.append(run)
            } else {
                merged = DownloadByteRange(
                    start: min(run.start, merged.start),
                    end: max(run.end, merged.end)
                )
            }
        }
        kept.append(merged)
        runs = kept.sorted { $0.start < $1.start }
    }

    func contains(_ range: DownloadByteRange) -> Bool {
        runs.contains { $0.start <= range.start && range.end <= $0.end }
    }

    func missingRanges(in range: DownloadByteRange) -> [DownloadByteRange] {
        var missing: [DownloadByteRange] = []
        var cursor = range.start
        for run in runs where run.end >= range.start && run.start <= range.end {
            if run.start > cursor {
                missing.append(DownloadByteRange(start: cursor, end: run.start - 1))
            }
            cursor = max(cursor, run.end + 1)
            if cursor > range.end { break }
        }
        if cursor <= range.end {
            missing.append(DownloadByteRange(start: cursor, end: range.end))
        }
        return missing
    }

    /// Contiguous cached byte count starting exactly at `start`, capped at `limit`.
    func prefixLength(from start: Int64, limit: Int64) -> Int64 {
        guard let run = runs.first(where: { $0.start <= start && start <= $0.end })
        else { return 0 }
        return min(run.end - start + 1, limit)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter ByteRangeSetTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): ByteRangeSet range math for sparse MP4 cache"`

---

### Task 3: RangeStore

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/RangeStoreTests.swift`

**Interfaces:**
- Consumes: `ByteRangeSet`, `DownloadByteRange`.
- Produces (all on `actor RangeStore`):
  - `init(root: URL)` — entries live at `root/{key}/` (`data.bin` + `ranges.json`); key is the cache key `"{videoId}"` or `"{videoId}:{versionId}"`.
  - `struct RangeStoreManifest: Codable, Equatable, Sendable { let etag: String; let totalByteCount: Int64; var ranges: ByteRangeSet }`
  - `func prepare(key: String, etag: String, totalByteCount: Int64) throws` — creates entry; wipes + recreates when stored etag/total differ.
  - `func write(key: String, at offset: Int64, data: Data) throws`
  - `func read(key: String, range: DownloadByteRange) throws -> Data?` — nil unless fully cached.
  - `func copyRange(key: String, range: DownloadByteRange, to handle: FileHandle) throws -> Bool` — chunked (1 MiB) copy for seeding; false unless fully cached.
  - `func manifest(key: String) -> RangeStoreManifest?`
  - `func remove(key: String)`
  - `func entryDir(key: String) -> URL` (nonisolated)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class RangeStoreTests: XCTestCase {
    private var root: URL!
    private var store: RangeStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = RangeStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func r(_ s: Int64, _ e: Int64) -> DownloadByteRange { .init(start: s, end: e) }

    func testWriteThenReadRoundTrip() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 10, data: Data(repeating: 7, count: 20))
        let data = try await store.read(key: "1", range: r(10, 29))
        XCTAssertEqual(data, Data(repeating: 7, count: 20))
    }

    func testReadReturnsNilForUncachedRange() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 10, data: Data(repeating: 7, count: 20))
        let data = try await store.read(key: "1", range: r(10, 40)) // 30-40 missing
        XCTAssertNil(data)
    }

    func testManifestPersistsAcrossInstances() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 0, data: Data(repeating: 1, count: 50))
        let reopened = RangeStore(root: root)
        let manifest = await reopened.manifest(key: "1")
        XCTAssertEqual(manifest?.etag, "\"a\"")
        XCTAssertEqual(manifest?.ranges.runs, [r(0, 49)])
    }

    func testPrepareWithNewEtagResetsEntry() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        try await store.write(key: "1", at: 0, data: Data(repeating: 1, count: 50))
        try await store.prepare(key: "1", etag: "\"b\"", totalByteCount: 100)
        let manifest = await store.manifest(key: "1")
        XCTAssertEqual(manifest?.ranges.runs, [])
        XCTAssertEqual(manifest?.etag, "\"b\"")
    }

    func testCorruptManifestWipesEntry() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 100)
        let manifestURL = store.entryDir(key: "1").appendingPathComponent("ranges.json")
        try Data("not json".utf8).write(to: manifestURL)
        let reopened = RangeStore(root: root)
        let manifest = await reopened.manifest(key: "1")
        XCTAssertNil(manifest)
    }

    func testCopyRangeChunked() async throws {
        try await store.prepare(key: "1", etag: "\"a\"", totalByteCount: 3_000_000)
        try await store.write(key: "1", at: 0, data: Data(repeating: 9, count: 3_000_000))
        let out = root.appendingPathComponent("out.bin")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        let copied = try await store.copyRange(key: "1", range: r(0, 2_999_999), to: handle)
        try handle.close()
        XCTAssertTrue(copied)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        XCTAssertEqual(size, 3_000_000)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter RangeStoreTests`. Expected: compile error "cannot find 'RangeStore'".

- [ ] **Step 3: Implement**

```swift
import Foundation

struct RangeStoreManifest: Codable, Equatable, Sendable {
    let etag: String
    let totalByteCount: Int64
    var ranges: ByteRangeSet
}

/// Sparse on-disk cache of remote MP4 byte ranges. One entry per cache key:
/// `data.bin` written at offsets (APFS keeps holes sparse) plus `ranges.json`
/// recording which runs are committed. Only committed runs are ever served.
actor RangeStore {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    nonisolated func entryDir(key: String) -> URL {
        root.appendingPathComponent(key, isDirectory: true)
    }

    private func dataURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("data.bin")
    }

    private func manifestURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("ranges.json")
    }

    func manifest(key: String) -> RangeStoreManifest? {
        guard let data = try? Data(contentsOf: manifestURL(key: key)) else { return nil }
        guard let manifest = try? JSONDecoder().decode(RangeStoreManifest.self, from: data),
              fileManager.fileExists(atPath: dataURL(key: key).path)
        else {
            remove(key: key) // corrupt: never trust, never repair
            return nil
        }
        return manifest
    }

    func prepare(key: String, etag: String, totalByteCount: Int64) throws {
        if let existing = manifest(key: key),
           existing.etag == etag, existing.totalByteCount == totalByteCount {
            return
        }
        remove(key: key)
        try fileManager.createDirectory(at: entryDir(key: key), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: dataURL(key: key).path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try save(RangeStoreManifest(etag: etag, totalByteCount: totalByteCount, ranges: ByteRangeSet()), key: key)
    }

    func write(key: String, at offset: Int64, data: Data) throws {
        guard var manifest = manifest(key: key), !data.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: dataURL(key: key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        manifest.ranges.insert(DownloadByteRange(start: offset, end: offset + Int64(data.count) - 1))
        try save(manifest, key: key)
    }

    func read(key: String, range: DownloadByteRange) throws -> Data? {
        guard let manifest = manifest(key: key), manifest.ranges.contains(range) else { return nil }
        let handle = try FileHandle(forReadingFrom: dataURL(key: key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.start))
        return try handle.read(upToCount: Int(range.length))
    }

    /// Chunked copy of a fully-cached range into `handle` (for download seeding).
    func copyRange(key: String, range: DownloadByteRange, to handle: FileHandle) throws -> Bool {
        guard let manifest = manifest(key: key), manifest.ranges.contains(range) else { return false }
        let input = try FileHandle(forReadingFrom: dataURL(key: key))
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(range.start))
        var remaining = range.length
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 1_048_576))
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            try handle.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        return true
    }

    func remove(key: String) {
        try? fileManager.removeItem(at: entryDir(key: key))
    }

    private func save(_ manifest: RangeStoreManifest, key: String) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(key: key), options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter RangeStoreTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): RangeStore sparse byte-range cache for MP4 streams"`

---

### Task 4: SegmentCache

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentCache.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentCacheTests.swift`

**Interfaces:**
- Produces (on `actor SegmentCache`):
  - `init(root: URL)` — packages live at `root/{videoId}/{hash}/{asset...}`.
  - `static func packageHash(forPlaylist data: Data) -> String` (nonisolated; SHA-256 hex, first 16 chars)
  - `func cachedData(videoId: Int, hash: String, asset: String) -> Data?`
  - `func store(videoId: Int, hash: String, asset: String, data: Data) throws` — atomic (tmp + rename); rejects traversal (`..`, leading `/`).
  - `func cachedAssets(videoId: Int, hash: String) -> Set<String>` — relative paths of cached files.
  - `func dropOtherPackages(videoId: Int, keeping hash: String)`
  - `func removeAll(videoId: Int)`
  - `func videoDir(videoId: Int) -> URL` (nonisolated)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class SegmentCacheTests: XCTestCase {
    private var root: URL!
    private var cache: SegmentCache!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = SegmentCache(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStoreAndFetch() async throws {
        try await cache.store(videoId: 7, hash: "abc", asset: "segment_00001.m4s", data: Data([1, 2, 3]))
        let data = await cache.cachedData(videoId: 7, hash: "abc", asset: "segment_00001.m4s")
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testNestedAssetPath() async throws {
        try await cache.store(videoId: 7, hash: "abc", asset: "subtitles/es.vtt", data: Data([9]))
        let data = await cache.cachedData(videoId: 7, hash: "abc", asset: "subtitles/es.vtt")
        XCTAssertEqual(data, Data([9]))
        let assets = await cache.cachedAssets(videoId: 7, hash: "abc")
        XCTAssertEqual(assets, ["subtitles/es.vtt"])
    }

    func testRejectsTraversal() async {
        await XCTAssertThrowsErrorAsync(
            try await self.cache.store(videoId: 7, hash: "abc", asset: "../evil", data: Data([1]))
        )
        let escaped = await cache.cachedData(videoId: 7, hash: "abc", asset: "../evil")
        XCTAssertNil(escaped)
    }

    func testDropOtherPackages() async throws {
        try await cache.store(videoId: 7, hash: "old", asset: "a.m4s", data: Data([1]))
        try await cache.store(videoId: 7, hash: "new", asset: "a.m4s", data: Data([2]))
        await cache.dropOtherPackages(videoId: 7, keeping: "new")
        let old = await cache.cachedData(videoId: 7, hash: "old", asset: "a.m4s")
        let new = await cache.cachedData(videoId: 7, hash: "new", asset: "a.m4s")
        XCTAssertNil(old)
        XCTAssertEqual(new, Data([2]))
    }

    func testPackageHashStableAndDistinct() {
        let a = SegmentCache.packageHash(forPlaylist: Data("one".utf8))
        let b = SegmentCache.packageHash(forPlaylist: Data("one".utf8))
        let c = SegmentCache.packageHash(forPlaylist: Data("two".utf8))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 16)
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SegmentCacheTests`. Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import CryptoKit
import Foundation

enum SegmentCacheError: Error, Equatable {
    case invalidAssetPath
}

/// On-disk cache of HLS package assets (init/segments/playlists/subtitles).
/// Keyed by (videoId, packageHash) where the hash comes from the media
/// playlist bytes — a server-side repackage (e.g. audio-language change)
/// yields a new hash, so stale segments can never be served.
actor SegmentCache {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    nonisolated static func packageHash(forPlaylist data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    nonisolated func videoDir(videoId: Int) -> URL {
        root.appendingPathComponent("\(videoId)", isDirectory: true)
    }

    private func packageDir(videoId: Int, hash: String) -> URL {
        videoDir(videoId: videoId).appendingPathComponent(hash, isDirectory: true)
    }

    /// Resolves `asset` under the package dir, rejecting path traversal.
    private func assetURL(videoId: Int, hash: String, asset: String) -> URL? {
        guard !asset.hasPrefix("/"), !asset.contains("..") else { return nil }
        return packageDir(videoId: videoId, hash: hash).appendingPathComponent(asset)
    }

    func cachedData(videoId: Int, hash: String, asset: String) -> Data? {
        guard let url = assetURL(videoId: videoId, hash: hash, asset: asset) else { return nil }
        return try? Data(contentsOf: url)
    }

    func store(videoId: Int, hash: String, asset: String, data: Data) throws {
        guard let url = assetURL(videoId: videoId, hash: hash, asset: asset) else {
            throw SegmentCacheError.invalidAssetPath
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        _ = try fileManager.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
    }

    func cachedAssets(videoId: Int, hash: String) -> Set<String> {
        let dir = packageDir(videoId: videoId, hash: hash)
        guard let enumerator = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var assets: Set<String> = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix(".")
            else { continue }
            let relative = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            assets.insert(relative)
        }
        return assets
    }

    func dropOtherPackages(videoId: Int, keeping hash: String) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: videoDir(videoId: videoId), includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent != hash {
            try? fileManager.removeItem(at: url)
        }
    }

    func removeAll(videoId: Int) {
        try? fileManager.removeItem(at: videoDir(videoId: videoId))
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter SegmentCacheTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): SegmentCache for HLS package assets"`

---

### Task 5: StreamCacheLRU

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamCacheLRU.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamCacheLRUTests.swift`

**Interfaces:**
- Produces (on `actor StreamCacheLRU`):
  - `init(managedDirs: [URL], budgetBytes: Int64)` — `managedDirs` are the parents whose immediate children are evictable entries (`stream/hls`'s children are per-video dirs, `stream/mp4`'s children are per-key dirs). Promoted downloads live elsewhere → exempt by construction.
  - `func touch(_ entryDir: URL)` — writes/updates `.access` marker mtime.
  - `func enforce()` — while total size of all entries > budget, delete the entry with the oldest access marker (entries with no marker count as oldest, using dir mtime).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class StreamCacheLRUTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeEntry(_ name: String, bytes: Int) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent("blob"))
        return dir
    }

    func testEvictsOldestTouchedFirstUntilUnderBudget() async {
        let a = makeEntry("a", bytes: 600)
        let b = makeEntry("b", bytes: 600)
        let c = makeEntry("c", bytes: 600)
        let lru = StreamCacheLRU(managedDirs: [root], budgetBytes: 1300)
        await lru.touch(a)
        try? await Task.sleep(for: .milliseconds(50))
        await lru.touch(b)
        try? await Task.sleep(for: .milliseconds(50))
        await lru.touch(c)
        await lru.enforce()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path)) // oldest gone
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
    }

    func testUnderBudgetEvictsNothing() async {
        let a = makeEntry("a", bytes: 100)
        let lru = StreamCacheLRU(managedDirs: [root], budgetBytes: 1_000_000)
        await lru.touch(a)
        await lru.enforce()
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter StreamCacheLRUTests`. Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// LRU over the temporary stream cache. Entries are the immediate child
/// directories of the managed roots; eviction granularity is a whole entry
/// (one video's stream cache). Promoted/downloaded files live outside the
/// managed roots, so they are exempt by construction.
actor StreamCacheLRU {
    private let managedDirs: [URL]
    private let budgetBytes: Int64
    private let fileManager = FileManager.default

    init(managedDirs: [URL], budgetBytes: Int64) {
        self.managedDirs = managedDirs
        self.budgetBytes = budgetBytes
    }

    func touch(_ entryDir: URL) {
        let marker = entryDir.appendingPathComponent(".access")
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: nil)
        } else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
        }
    }

    func enforce() {
        var entries: [(dir: URL, accessed: Date, size: Int64)] = []
        for managed in managedDirs {
            let children = (try? fileManager.contentsOfDirectory(
                at: managed, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                entries.append((child, accessDate(of: child), directorySize(child)))
            }
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > budgetBytes else { return }
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            try? fileManager.removeItem(at: entry.dir)
            total -= entry.size
            if total <= budgetBytes { break }
        }
    }

    private func accessDate(of dir: URL) -> Date {
        let marker = dir.appendingPathComponent(".access")
        let path = fileManager.fileExists(atPath: marker.path) ? marker.path : dir.path
        let attrs = try? fileManager.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter StreamCacheLRUTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): StreamCacheLRU 10GB eviction for temp stream cache"`

---

### Task 6: HLSManifestParser

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/HLSManifestParser.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/HLSManifestParserTests.swift`

**Interfaces:**
- Produces:
  - `enum HLSManifestParser`
  - `static func mediaAssets(inMediaPlaylist text: String) -> [String]` — segment URIs (non-# lines) plus the `#EXT-X-MAP:URI="…"` init file, order preserved, init first, no duplicates.
  - `static func referencedPlaylists(inMasterPlaylist text: String) -> [String]` — variant playlist lines (non-# lines) plus `URI="…"` attributes from `#EXT-X-MEDIA` tags.

Server playlist shapes (from `hls.py`): master has `#EXT-X-MEDIA:TYPE=SUBTITLES,…,URI="subtitles/es.m3u8"` lines and a `video.m3u8` variant line; media playlist has `#EXT-X-MAP:URI="init.mp4"` and `segment_00000.m4s`… lines; subtitle media playlists reference one `.vtt` file. All URIs relative.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class HLSManifestParserTests: XCTestCase {
    func testMediaAssetsExtractsInitAndSegments() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        segment_00000.m4s
        #EXTINF:6.0,
        segment_00001.m4s
        #EXT-X-ENDLIST
        """
        XCTAssertEqual(
            HLSManifestParser.mediaAssets(inMediaPlaylist: playlist),
            ["init.mp4", "segment_00000.m4s", "segment_00001.m4s"]
        )
    }

    func testMediaAssetsHandlesSubtitlePlaylist() {
        let playlist = """
        #EXTM3U
        #EXTINF:5400.000,
        es.vtt
        #EXT-X-ENDLIST
        """
        XCTAssertEqual(HLSManifestParser.mediaAssets(inMediaPlaylist: playlist), ["es.vtt"])
    }

    func testReferencedPlaylists() {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="es",NAME="Spanish",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles/es.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,SUBTITLES="subs"
        video.m3u8
        """
        XCTAssertEqual(
            HLSManifestParser.referencedPlaylists(inMasterPlaylist: master),
            ["subtitles/es.m3u8", "video.m3u8"]
        )
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter HLSManifestParserTests`. Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Minimal parser for the playlists our own server generates (`hls.py`):
/// single variant, relative URIs, fMP4 init via EXT-X-MAP, subtitle groups
/// via EXT-X-MEDIA. Not a general M3U8 parser.
enum HLSManifestParser {
    static func mediaAssets(inMediaPlaylist text: String) -> [String] {
        var assets: [String] = []
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attributeValue("URI", in: line), !assets.contains(uri) {
                    assets.insert(uri, at: 0)
                }
            } else if !line.hasPrefix("#"), !assets.contains(line) {
                assets.append(line)
            }
        }
        return assets
    }

    static func referencedPlaylists(inMasterPlaylist text: String) -> [String] {
        var playlists: [String] = []
        for line in lines(of: text) {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                if let uri = attributeValue("URI", in: line), !playlists.contains(uri) {
                    playlists.append(uri)
                }
            } else if !line.hasPrefix("#"), !playlists.contains(line) {
                playlists.append(line)
            }
        }
        return playlists
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func attributeValue(_ name: String, in line: String) -> String? {
        guard let nameRange = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[nameRange.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter HLSManifestParserTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): HLS playlist asset parser"`

---

### Task 7: StreamCache facade

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamCache.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamCacheTests.swift`

**Interfaces:**
- Consumes: `RangeStore`, `SegmentCache`, `StreamCacheLRU`.
- Produces:
  - `public final class StreamCache: @unchecked Sendable`
  - `public init(root: URL? = nil, budgetBytes: Int64 = StreamCache.defaultBudgetBytes)` — default root `Caches/stream`; creates `root/hls` and `root/mp4`; sets `isExcludedFromBackup` on root.
  - `public static let defaultBudgetBytes: Int64` (10 GB)
  - `let ranges: RangeStore` (internal), `let segments: SegmentCache` (internal), `let lru: StreamCacheLRU` (internal)
  - `func touchAndEnforce(entryDir: URL)` (internal) — touches, then enforces on a detached task.
  - `public func removeVideo(id: Int)` — drops both HLS packages and any `mp4/{id}` / `mp4/{id}:*` entries.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PatataTubeKit

final class StreamCacheTests: XCTestCase {
    func testLayoutAndRemoveVideo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamCache(root: root)
        try await cache.segments.store(videoId: 3, hash: "h", asset: "a.m4s", data: Data([1]))
        try await cache.ranges.prepare(key: "3:9", etag: "\"e\"", totalByteCount: 10)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("hls/3/h/a.m4s").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mp4/3:9/data.bin").path))

        await cache.removeVideo(id: 3)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("hls/3").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mp4/3:9").path))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter StreamCacheTests`. Expected: compile error.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Owner of the temporary stream cache: HLS segment store + MP4 range store +
/// LRU budget. One instance is shared by the playback proxy (read-through
/// writes) and the download manager (seeding, promotion).
public final class StreamCache: @unchecked Sendable {
    public static let defaultBudgetBytes: Int64 = 10 * 1024 * 1024 * 1024

    public let root: URL
    let ranges: RangeStore
    let segments: SegmentCache
    let lru: StreamCacheLRU

    public init(root: URL? = nil, budgetBytes: Int64 = StreamCache.defaultBudgetBytes) {
        let fileManager = FileManager.default
        let resolved = root ?? fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stream", isDirectory: true)
        self.root = resolved
        let hlsRoot = resolved.appendingPathComponent("hls", isDirectory: true)
        let mp4Root = resolved.appendingPathComponent("mp4", isDirectory: true)
        try? fileManager.createDirectory(at: hlsRoot, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: mp4Root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = resolved
        try? dir.setResourceValues(values)
        self.segments = SegmentCache(root: hlsRoot)
        self.ranges = RangeStore(root: mp4Root)
        self.lru = StreamCacheLRU(managedDirs: [hlsRoot, mp4Root], budgetBytes: budgetBytes)
    }

    /// Record use of an entry and enforce the budget off the caller's path.
    func touchAndEnforce(entryDir: URL) {
        Task.detached(priority: .utility) { [lru] in
            await lru.touch(entryDir)
            await lru.enforce()
        }
    }

    public func removeVideo(id: Int) async {
        await segments.removeAll(videoId: id)
        let mp4Root = root.appendingPathComponent("mp4", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: mp4Root, includingPropertiesForKeys: nil
        )) ?? []
        for child in children {
            let name = child.lastPathComponent
            if name == "\(id)" || name.hasPrefix("\(id):") {
                await ranges.remove(key: name)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter StreamCacheTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): StreamCache facade tying ranges, segments, LRU"`

---

### Task 8: StreamProxy

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift`

**Interfaces:**
- Consumes: `StreamCache`, `CredentialStore` (existing: `.baseURL: URL?`, `.token: String?`), `HLSManifestParser`, FlyingFox.
- Produces:
  - `public final class StreamProxy: @unchecked Sendable`
  - `public init(cache: StreamCache, credentials: CredentialStore, session: URLSession = .shared, offlineRoot: URL? = nil)` — `offlineRoot` is where promoted HLS packages live (Task 10 wires the real one).
  - `public func start() async` — starts server on `.loopback(port: 0)`, `waitUntilListening()`, records port. Failure leaves `port == nil` (callers fall back to direct URLs).
  - `public func stop() async`
  - `public private(set) var port: UInt16?` (thread-safe via lock)
  - `public let secret: String`
  - `public func hlsURL(videoId: Int, versionId: Int?) -> URL?` → `http://127.0.0.1:{port}/{secret}/hls/{videoId}/{versionId ?? 0}/master.m3u8`
  - `public func mp4URL(videoId: Int, versionId: Int?) -> URL?` → `.../{secret}/mp4/{videoId}/{versionId ?? 0}`
  - `public func offlineHLSURL(videoId: Int, versionId: Int?) -> URL?` → `.../{secret}/offline/{videoId}/{versionId ?? 0}/master.m3u8`
- Routes:
  - `GET /{secret}/hls/:id/:v/*` — HLS read-through
  - `GET /{secret}/mp4/:id/:v` — MP4 range read-through
  - `GET /{secret}/offline/:id/:v/*` — serve promoted package files from `offlineRoot/hls-{id}[_v{v}]/`
- Behavior contract:
  - Upstream requests carry `Authorization: Bearer {token}`; upstream HLS URL is `{base}/videos/{id}/hls/{asset}` plus `?version_id={v}` when `v != 0`; upstream MP4 URL is `{base}/videos/{id}/stream` plus `?version_id={v}` when `v != 0` (matches `Video.streamPath` = `/videos/{id}/stream`).
  - `.m3u8` assets: always fetched upstream when reachable. The `video.m3u8` response sets the current package hash for that video (`SegmentCache.packageHash`), triggers `dropOtherPackages`, and is also stored in the cache. If upstream is unreachable and a cached copy exists under the current hash, serve the cached copy.
  - Non-playlist assets: look up under the current hash → hit serves from disk; miss single-flights an upstream fetch, stores (best-effort — store failure still serves the fetched bytes), serves. If no current hash is known (app relaunch), the proxy fetches `video.m3u8` first to establish it.
  - MP4: on first touch per key, single-flight a probe (`Range: bytes=0-0`, reusing `SegmentedDownloadStore.validateProbe`) → `ranges.prepare(key:etag:total:)`. Serve requested range capped to 8 MB window: compute `missingRanges`, fetch each missing subrange upstream (`Range: bytes=a-b`, expect 206 with matching ETag; ETag mismatch → `prepare` with new etag (resets) → treat whole window as missing), `ranges.write` each, then `ranges.read` the window and reply `206` with `Content-Range: bytes {start}-{end}/{total}`, `Content-Type: video/mp4`, `Accept-Ranges: bytes`. If cache read/write fails, fetch the window upstream and return it uncached.
  - Requests with a wrong secret or unparsable id: `404`. Upstream 4xx/5xx on a required fetch: `502`.
  - Every cache hit/write calls `cache.touchAndEnforce(entryDir:)` with the video's entry dir (`segments.videoDir(videoId:)` or `ranges.entryDir(key:)`).
- `Content-Type` map: `.m3u8` → `application/vnd.apple.mpegurl`, `.vtt` → `text/vtt`, `.m4s` → `video/iso.segment`, `.mp4` → `video/mp4`, else `application/octet-stream`.

- [ ] **Step 1: Write the failing tests**

Tests use the existing `MockURLProtocol` (see `Tests/PatataTubeKitTests/MockURLProtocol.swift` — study its registration pattern first and reuse it exactly) for the upstream, and a real `URLSession.shared` request against `127.0.0.1:{port}` for the client side.

```swift
import XCTest
@testable import PatataTubeKit

final class StreamProxyTests: XCTestCase {
    private var root: URL!
    private var cache: StreamCache!
    private var credentials: CredentialStore!
    private var proxy: StreamProxy!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = StreamCache(root: root)
        credentials = CredentialStore(service: "test-\(UUID().uuidString)")
        credentials.baseURL = URL(string: "https://upstream.test")
        credentials.token = "tok"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        proxy = StreamProxy(
            cache: cache,
            credentials: credentials,
            session: URLSession(configuration: config)
        )
        await proxy.start()
    }

    override func tearDown() async throws {
        await proxy.stop()
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func get(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func testHLSSegmentReadThroughCachesAndServesFromDiskSecondTime() async throws {
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nsegment_00000.m4s\n#EXT-X-ENDLIST\n"
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: Data("#EXTM3U\nvideo.m3u8\n".utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: Data(playlist.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/segment_00000.m4s", data: Data(repeating: 4, count: 64))

        let master = proxy.hlsURL(videoId: 5, versionId: nil)!
        _ = try await get(master)
        let mediaURL = master.deletingLastPathComponent().appendingPathComponent("video.m3u8")
        _ = try await get(mediaURL)
        let segURL = master.deletingLastPathComponent().appendingPathComponent("segment_00000.m4s")
        let (first, response) = try await get(segURL)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(first, Data(repeating: 4, count: 64))

        let upstreamCallsAfterFirst = MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s")
        let (second, _) = try await get(segURL)
        XCTAssertEqual(second, first)
        XCTAssertEqual(
            MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s"),
            upstreamCallsAfterFirst // no new upstream fetch
        )
    }

    func testWrongSecretIs404() async throws {
        let good = proxy.hlsURL(videoId: 5, versionId: nil)!
        let bad = URL(string: good.absoluteString.replacingOccurrences(of: proxy.secret, with: "nope"))!
        let (_, response) = try await get(bad)
        XCTAssertEqual(response.statusCode, 404)
    }

    func testMP4RangeReadThroughFillsHolesAndServes206() async throws {
        let body = Data((0..<1000).map { UInt8($0 % 251) })
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")

        let url = proxy.mp4URL(videoId: 9, versionId: nil)!
        let (data, response) = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, body.subdata(in: 100..<300))
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"),
            "bytes 100-299/1000"
        )

        // Second identical request served from cache: ranged upstream count unchanged.
        let count = MockURLProtocol.requestCount(path: "/videos/9/stream")
        _ = try await get(url, range: "bytes=100-299")
        XCTAssertEqual(MockURLProtocol.requestCount(path: "/videos/9/stream"), count)
    }

    func testMP4OpenEndedRangeCappedAt8MB() async throws {
        let body = Data(repeating: 6, count: 9 * 1024 * 1024)
        MockURLProtocol.stubRanged(path: "/videos/9/stream", fullBody: body, etag: "\"e1\"")
        let url = proxy.mp4URL(videoId: 9, versionId: nil)!
        let (data, response) = try await get(url, range: "bytes=0-")
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data.count, 8 * 1024 * 1024)
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Content-Range"),
            "bytes 0-\(8 * 1024 * 1024 - 1)/\(9 * 1024 * 1024)"
        )
    }
}
```

`MockURLProtocol` will need two helpers if it lacks them (add in the test file or extend the mock, following its existing style): `stub(path:data:)` returning 200 with the data, `stubRanged(path:fullBody:etag:)` implementing `Range: bytes=a-b` / `bytes=0-0` probe semantics (206, `Content-Range`, `ETag`, `Accept-Ranges: bytes`, `Content-Length`), and `requestCount(path:)` / `reset()`. If `CredentialStore(service:)` has a different init signature, read `CredentialStore.swift` and construct it the way `APIClientReadTests.swift` does.

- [ ] **Step 2: Run to verify failure** — `swift test --filter StreamProxyTests`. Expected: compile error.

- [ ] **Step 3: Implement StreamProxy**

```swift
import FlyingFox
import Foundation

/// Loopback read-through caching proxy. AVPlayer requests
/// `http://127.0.0.1:{port}/{secret}/...`; the proxy serves from StreamCache,
/// fetching misses upstream with the Bearer token. Playback must survive any
/// cache failure: fall back to pass-through, never block.
public final class StreamProxy: @unchecked Sendable {
    private static let mp4Window: Int64 = 8 * 1024 * 1024

    public let secret = UUID().uuidString
    private let cache: StreamCache
    private let credentials: CredentialStore
    private let session: URLSession
    private let offlineRoot: URL?
    private let lock = NSLock()
    private var _port: UInt16?
    private var serverTask: Task<Void, Never>?
    private var server: HTTPServer?
    /// videoId → current package hash, set by the latest video.m3u8 fetch.
    private var currentHash: [Int: String] = [:]
    private let singleFlight = SingleFlight()

    public var port: UInt16? { lock.withLock { _port } }

    public init(
        cache: StreamCache,
        credentials: CredentialStore,
        session: URLSession = .shared,
        offlineRoot: URL? = nil
    ) {
        self.cache = cache
        self.credentials = credentials
        self.session = session
        self.offlineRoot = offlineRoot
    }

    public func start() async {
        let server = HTTPServer(address: .loopback(port: 0))
        await server.appendRoute("GET /\(secret)/hls/:id/:v/*") { [weak self] request in
            await self?.handleHLS(request) ?? HTTPResponse(statusCode: .notFound)
        }
        await server.appendRoute("GET /\(secret)/mp4/:id/:v") { [weak self] request in
            await self?.handleMP4(request) ?? HTTPResponse(statusCode: .notFound)
        }
        await server.appendRoute("GET /\(secret)/offline/:id/:v/*") { [weak self] request in
            await self?.handleOffline(request) ?? HTTPResponse(statusCode: .notFound)
        }
        self.server = server
        serverTask = Task { try? await server.run() }
        do {
            try await server.waitUntilListening()
            if case let .ip4(_, port: listeningPort)? = await server.listeningAddress {
                lock.withLock { _port = listeningPort }
            }
        } catch {
            // Leave port nil: callers fall back to direct remote URLs.
        }
    }

    public func stop() async {
        await server?.stop()
        serverTask?.cancel()
        lock.withLock { _port = nil }
    }

    // MARK: - Public URL builders

    public func hlsURL(videoId: Int, versionId: Int?) -> URL? {
        localURL(kind: "hls", videoId: videoId, versionId: versionId, suffix: "/master.m3u8")
    }

    public func mp4URL(videoId: Int, versionId: Int?) -> URL? {
        localURL(kind: "mp4", videoId: videoId, versionId: versionId, suffix: "")
    }

    public func offlineHLSURL(videoId: Int, versionId: Int?) -> URL? {
        localURL(kind: "offline", videoId: videoId, versionId: versionId, suffix: "/master.m3u8")
    }

    private func localURL(kind: String, videoId: Int, versionId: Int?, suffix: String) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(secret)/\(kind)/\(videoId)/\(versionId ?? 0)\(suffix)")
    }

    // MARK: - Upstream helpers

    private struct RouteParams {
        let videoId: Int
        let versionId: Int?
        let asset: String
    }

    private func params(of request: HTTPRequest) -> RouteParams? {
        guard let idText = request.routeParameters["id"], let videoId = Int(idText),
              let vText = request.routeParameters["v"], let v = Int(vText)
        else { return nil }
        // Path after ".../{id}/{v}/" is the asset (may contain slashes).
        let marker = "/\(idText)/\(vText)/"
        let asset: String
        if let range = request.path.range(of: marker) {
            asset = String(request.path[range.upperBound...])
                .removingPercentEncoding ?? ""
        } else {
            asset = ""
        }
        return RouteParams(videoId: videoId, versionId: v == 0 ? nil : v, asset: asset)
    }

    private func upstreamURL(path: String, versionId: Int?) -> URL? {
        guard let base = credentials.baseURL,
              var comps = URLComponents(
                  url: base.appendingPathComponent(path),
                  resolvingAgainstBaseURL: false
              )
        else { return nil }
        if let versionId {
            comps.queryItems = (comps.queryItems ?? [])
                + [URLQueryItem(name: "version_id", value: "\(versionId)")]
        }
        return comps.url
    }

    private func upstreamRequest(url: URL, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = credentials.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    private func contentType(for asset: String) -> String {
        switch (asset as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "vtt": return "text/vtt"
        case "m4s": return "video/iso.segment"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    // MARK: - HLS

    private func handleHLS(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = params(of: request), !params.asset.isEmpty else {
            return HTTPResponse(statusCode: .notFound)
        }
        let headers: [HTTPHeader: String] = [
            .contentType: contentType(for: params.asset)
        ]
        if params.asset.hasSuffix(".m3u8") {
            return await servePlaylist(params, headers: headers)
        }
        return await serveHLSAsset(params, headers: headers)
    }

    private func servePlaylist(
        _ params: RouteParams, headers: [HTTPHeader: String]
    ) async -> HTTPResponse {
        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/hls/\(params.asset)",
            versionId: params.versionId
        ) else { return HTTPResponse(statusCode: .badGateway) }
        do {
            let (data, response) = try await session.data(for: upstreamRequest(url: url))
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            if params.asset == "video.m3u8" {
                let hash = SegmentCache.packageHash(forPlaylist: data)
                lock.withLock { currentHash[params.videoId] = hash }
                await cache.segments.dropOtherPackages(videoId: params.videoId, keeping: hash)
            }
            if let hash = lock.withLock({ currentHash[params.videoId] }) {
                try? await cache.segments.store(
                    videoId: params.videoId, hash: hash, asset: params.asset, data: data
                )
            }
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        } catch {
            // Unreachable upstream: last-known cached playlist keeps playback alive.
            if let hash = lock.withLock({ currentHash[params.videoId] }),
               let cached = await cache.segments.cachedData(
                   videoId: params.videoId, hash: hash, asset: params.asset
               ) {
                return HTTPResponse(statusCode: .ok, headers: headers, body: cached)
            }
            return HTTPResponse(statusCode: .badGateway)
        }
    }

    private func serveHLSAsset(
        _ params: RouteParams, headers: [HTTPHeader: String]
    ) async -> HTTPResponse {
        var hash = lock.withLock { currentHash[params.videoId] }
        if hash == nil {
            // App relaunch mid-session: establish the package hash first.
            _ = await servePlaylist(
                RouteParams(videoId: params.videoId, versionId: params.versionId, asset: "video.m3u8"),
                headers: [:]
            )
            hash = lock.withLock { currentHash[params.videoId] }
        }
        guard let hash else { return HTTPResponse(statusCode: .badGateway) }

        if let cached = await cache.segments.cachedData(
            videoId: params.videoId, hash: hash, asset: params.asset
        ) {
            cache.touchAndEnforce(entryDir: cache.segments.videoDir(videoId: params.videoId))
            return HTTPResponse(statusCode: .ok, headers: headers, body: cached)
        }

        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/hls/\(params.asset)",
            versionId: params.versionId
        ) else { return HTTPResponse(statusCode: .badGateway) }
        do {
            let data = try await singleFlight.run(key: url.absoluteString) { [session] in
                let (data, response) = try await session.data(for: self.upstreamRequest(url: url))
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                    throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                return data
            }
            try? await cache.segments.store(
                videoId: params.videoId, hash: hash, asset: params.asset, data: data
            )
            cache.touchAndEnforce(entryDir: cache.segments.videoDir(videoId: params.videoId))
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        } catch {
            return HTTPResponse(statusCode: .badGateway)
        }
    }

    // MARK: - MP4

    private func handleMP4(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = params(of: request) ?? mp4Params(of: request) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let key = params.versionId.map { "\(params.videoId):\($0)" } ?? "\(params.videoId)"
        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/stream",
            versionId: params.versionId
        ) else { return HTTPResponse(statusCode: .badGateway) }

        // Ensure the entry exists with a validated ETag + total.
        var manifest = await cache.ranges.manifest(key: key)
        if manifest == nil {
            do {
                _ = try await singleFlight.run(key: "probe:\(key)") { [self] in
                    let (body, response) = try await session.data(
                        for: upstreamRequest(url: url, range: "bytes=0-0")
                    )
                    guard let http = response as? HTTPURLResponse else {
                        throw SegmentedDownloadError.invalidProbe
                    }
                    let probe = try SegmentedDownloadStore.validateProbe(http, bodyCount: body.count)
                    try await cache.ranges.prepare(
                        key: key, etag: probe.etag, totalByteCount: probe.totalByteCount
                    )
                    return Data()
                }
            } catch {
                return HTTPResponse(statusCode: .badGateway)
            }
            manifest = await cache.ranges.manifest(key: key)
        }
        guard let manifest else { return HTTPResponse(statusCode: .badGateway) }
        let total = manifest.totalByteCount

        // Parse Range (default whole file), cap window at 8 MB.
        let requested = parseRange(request.headers[HTTPHeader("Range")], total: total)
            ?? DownloadByteRange(start: 0, end: total - 1)
        guard requested.start >= 0, requested.start < total else {
            return HTTPResponse(statusCode: HTTPStatusCode(416, phrase: "Range Not Satisfiable"))
        }
        let window = DownloadByteRange(
            start: requested.start,
            end: min(requested.end, min(requested.start + Self.mp4Window - 1, total - 1))
        )

        // Fill holes.
        let missing = manifest.ranges.missingRanges(in: window)
        for hole in missing {
            do {
                let (body, response) = try await session.data(
                    for: upstreamRequest(url: url, range: hole.headerValue)
                )
                guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                    throw APIError.badStatus(0)
                }
                if http.value(forHTTPHeaderField: "ETag") != manifest.etag {
                    // Entity changed under us: reset and serve this window uncached.
                    await cache.ranges.remove(key: key)
                    if let response = await passthroughMP4(
                        window: window, total: total, body: nil, url: url
                    ) {
                        return response
                    }
                    return HTTPResponse(statusCode: .badGateway)
                }
                try await cache.ranges.write(key: key, at: hole.start, data: body)
            } catch {
                // Cache path failed — serve the window uncached (pass-through).
                if let response = await passthroughMP4(window: window, total: total, body: nil, url: url) {
                    return response
                }
                return HTTPResponse(statusCode: .badGateway)
            }
        }

        guard let data = try? await cache.ranges.read(key: key, range: window) else {
            if let response = await passthroughMP4(window: window, total: total, body: nil, url: url) {
                return response
            }
            return HTTPResponse(statusCode: .badGateway)
        }
        cache.touchAndEnforce(entryDir: cache.ranges.entryDir(key: key))
        return partialResponse(data: data, window: window, total: total)
    }

    /// FlyingFox route params for the `mp4` route (no trailing asset segment).
    private func mp4Params(of request: HTTPRequest) -> RouteParams? {
        guard let idText = request.routeParameters["id"], let videoId = Int(idText),
              let vText = request.routeParameters["v"], let v = Int(vText)
        else { return nil }
        return RouteParams(videoId: videoId, versionId: v == 0 ? nil : v, asset: "")
    }

    private func passthroughMP4(
        window: DownloadByteRange, total: Int64, body: Data?, url: URL
    ) async -> HTTPResponse? {
        if let body { return partialResponse(data: body, window: window, total: total) }
        guard let (data, response) = try? await session.data(
            for: upstreamRequest(url: url, range: window.headerValue)
        ), (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
        return partialResponse(data: data, window: window, total: total)
    }

    private func partialResponse(
        data: Data, window: DownloadByteRange, total: Int64
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: HTTPStatusCode(206, phrase: "Partial Content"),
            headers: [
                .contentType: "video/mp4",
                HTTPHeader("Content-Range"): "bytes \(window.start)-\(window.end)/\(total)",
                HTTPHeader("Accept-Ranges"): "bytes",
            ],
            body: data
        )
    }

    /// Parses `bytes=a-b` / `bytes=a-`; suffix form `bytes=-n` maps to the
    /// last n bytes. Returns nil for absent/invalid headers.
    private func parseRange(_ header: String?, total: Int64) -> DownloadByteRange? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 {
            return DownloadByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(parts[0]) else { return nil }
        let end = Int64(parts[1]) ?? (total - 1)
        guard end >= start else { return nil }
        return DownloadByteRange(start: start, end: min(end, total - 1))
    }

    // MARK: - Offline

    private func handleOffline(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = params(of: request), !params.asset.isEmpty,
              let offlineRoot,
              !params.asset.contains(".."), !params.asset.hasPrefix("/")
        else { return HTTPResponse(statusCode: .notFound) }
        let suffix = params.versionId.map { "_v\($0)" } ?? ""
        let file = offlineRoot
            .appendingPathComponent("hls-\(params.videoId)\(suffix)", isDirectory: true)
            .appendingPathComponent(params.asset)
        guard let data = try? Data(contentsOf: file) else {
            return HTTPResponse(statusCode: .notFound)
        }
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: contentType(for: params.asset)],
            body: data
        )
    }
}

/// Deduplicates concurrent identical upstream fetches (player + downloader).
actor SingleFlight {
    private var inFlight: [String: Task<Data, Error>] = [:]

    func run(
        key: String,
        _ operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
```

API-drift warnings for the implementer (fix on compile errors, keep semantics):
- `HTTPServer.listeningAddress` returns a `Socket.Address`; the `.ip4(_, port:)` pattern may differ by FlyingFox version — check the package source under `.build/checkouts/FlyingFox` for the enum shape.
- `HTTPStatusCode(206, phrase:)` — if no such initializer, use the provided static (e.g. `.partialContent`) or the documented init.
- `request.headers[HTTPHeader("Range")]` — confirm subscript vs. accessor in the checked-out source.
- If `handleHLS`'s wildcard `*` doesn't expose the tail path, derive `asset` from `request.path` (the code above already does).

- [ ] **Step 4: Run to verify pass** — `swift test --filter StreamProxyTests`. Expected: PASS. Also run full `swift test` (no regressions).

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): StreamProxy loopback read-through caching server"`

---

### Task 9: Seed MP4 downloads from the stream cache

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamCache.swift` (add `seedSegments`)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (~line 168: add `streamCache` property + init param; ~line 655 in `downloadVideo`: seed hook after `SegmentedDownloadManifest.make`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamCacheSeedTests.swift`

**Interfaces:**
- Consumes: `SegmentedDownloadStore` (`partURL(cacheKey:index:)`, `write(_:)`, `assemble(manifest:destination:)`), `RangeStore.copyRange`, `RangeStoreManifest`.
- Produces:
  - On `StreamCache`: `func seedSegments(manifest: SegmentedDownloadManifest, into store: SegmentedDownloadStore) async -> SegmentedDownloadManifest`
  - On `CacheManager`: `init` gains `streamCache: StreamCache? = nil` (both the internal init and the public convenience init pass it through); stored as `let streamCache: StreamCache?` (internal).

Seeding rule: for each segment, copy the longest cached **prefix** starting at `segment.range.start` (bounded by segment length) into the part file and set `persistedByteCount`; full-length prefix marks `isComplete`. Cached runs that don't start at the segment start are ignored — the resume machinery (`startIncompleteSegments`) only understands byte-count-from-start, and streamed content is overwhelmingly prefix-contiguous. Seed only when the RangeStore etag and total match the probe's.

- [ ] **Step 1: Read the resume path** — Read `CacheManager.swift` lines 779–920 (`startSegmentedAttempt` + `startIncompleteSegments`). Confirm: segments with `isComplete == true` are skipped, and partial parts resume from `persistedByteCount` (the same contract `resumeInterrupted` relies on). If `startIncompleteSegments` finds zero incomplete segments, note what happens (likely nothing) — the seed hook below handles the all-complete case before ever calling it.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class StreamCacheSeedTests: XCTestCase {
    private var root: URL!
    private var cache: StreamCache!
    private var store: SegmentedDownloadStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cache = StreamCache(root: root.appendingPathComponent("stream"))
        store = SegmentedDownloadStore(root: root.appendingPathComponent("videos"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManifest(total: Int64, streams: Int) throws -> SegmentedDownloadManifest {
        try SegmentedDownloadManifest.make(
            videoId: 1, versionId: nil,
            remoteURL: URL(string: "https://u.test/videos/1/stream")!,
            requestedStreamCount: streams, totalByteCount: total, etag: "\"e\""
        )
    }

    func testSeedsPrefixesFromCachedRanges() async throws {
        // 100 bytes, 2 segments: [0-49], [50-99]. Cache 0-29 and 50-99.
        try await cache.ranges.prepare(key: "1", etag: "\"e\"", totalByteCount: 100)
        try await cache.ranges.write(key: "1", at: 0, data: Data(repeating: 1, count: 30))
        try await cache.ranges.write(key: "1", at: 50, data: Data(repeating: 2, count: 50))
        let manifest = try makeManifest(total: 100, streams: 2)

        let seeded = await cache.seedSegments(manifest: manifest, into: store)

        XCTAssertEqual(seeded.segments[0].persistedByteCount, 30)
        XCTAssertFalse(seeded.segments[0].isComplete)
        XCTAssertEqual(seeded.segments[1].persistedByteCount, 50)
        XCTAssertTrue(seeded.segments[1].isComplete)
        let part0 = try Data(contentsOf: store.partURL(cacheKey: "1", index: 0))
        XCTAssertEqual(part0, Data(repeating: 1, count: 30))
        // Manifest persisted so a later resume sees the seeded state.
        let loaded = try store.load(cacheKey: "1")
        XCTAssertEqual(loaded, seeded)
    }

    func testNoSeedOnEtagMismatch() async throws {
        try await cache.ranges.prepare(key: "1", etag: "\"other\"", totalByteCount: 100)
        try await cache.ranges.write(key: "1", at: 0, data: Data(repeating: 1, count: 100))
        let manifest = try makeManifest(total: 100, streams: 1)
        let seeded = await cache.seedSegments(manifest: manifest, into: store)
        XCTAssertEqual(seeded, manifest) // untouched
    }

    func testNoSeedWithoutCacheEntry() async throws {
        let manifest = try makeManifest(total: 100, streams: 1)
        let seeded = await cache.seedSegments(manifest: manifest, into: store)
        XCTAssertEqual(seeded, manifest)
    }
}
```

- [ ] **Step 3: Run to verify failure** — `swift test --filter StreamCacheSeedTests`. Expected: compile error ("seedSegments" not found).

- [ ] **Step 4: Implement `seedSegments` on StreamCache**

```swift
    /// Pre-fills segmented-download part files from streamed bytes. Only
    /// prefixes count (the resume machinery models "bytes from segment
    /// start"); only applies when the cached entity matches the probe.
    func seedSegments(
        manifest: SegmentedDownloadManifest,
        into store: SegmentedDownloadStore
    ) async -> SegmentedDownloadManifest {
        let key = manifest.cacheKey
        guard let cached = await ranges.manifest(key: key),
              cached.etag == manifest.etag,
              cached.totalByteCount == manifest.totalByteCount
        else { return manifest }

        var seeded = manifest
        var didSeed = false
        for index in seeded.segments.indices {
            let segment = seeded.segments[index]
            let prefix = cached.ranges.prefixLength(
                from: segment.range.start, limit: segment.range.length
            )
            guard prefix > 0 else { continue }
            let part = store.partURL(cacheKey: key, index: segment.index)
            do {
                try FileManager.default.createDirectory(
                    at: part.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: part.path, contents: nil)
                let handle = try FileHandle(forWritingTo: part)
                defer { try? handle.close() }
                let range = DownloadByteRange(
                    start: segment.range.start, end: segment.range.start + prefix - 1
                )
                guard try await ranges.copyRange(key: key, range: range, to: handle) else {
                    try? FileManager.default.removeItem(at: part)
                    continue
                }
                try handle.synchronize()
            } catch {
                try? FileManager.default.removeItem(at: part)
                continue
            }
            seeded.segments[index].persistedByteCount = prefix
            if prefix == segment.range.length {
                seeded.segments[index].isComplete = true
            }
            didSeed = true
        }
        guard didSeed else { return manifest }
        do {
            try store.write(seeded)
            return seeded
        } catch {
            return manifest
        }
    }
```

- [ ] **Step 5: Run to verify pass** — `swift test --filter StreamCacheSeedTests`. Expected: PASS.

- [ ] **Step 6: Wire into CacheManager**

In `CacheManager.swift`:

1. Add stored property next to `segmentedStore` (~line 147): `let streamCache: StreamCache?`
2. Internal init (~line 178): add parameter `streamCache: StreamCache? = nil`, assign before `super.init()`.
3. Public convenience init (~line 167): add `streamCache: StreamCache? = nil` and pass through.
4. In `downloadVideo` (~line 655), replace the fresh-manifest block:

```swift
            var manifest = try SegmentedDownloadManifest.make(
                videoId: id,
                versionId: versionId,
                remoteURL: remote,
                requestedStreamCount: streamCount,
                totalByteCount: probe.totalByteCount,
                etag: probe.etag
            )
            if let streamCache {
                manifest = await streamCache.seedSegments(manifest: manifest, into: segmentedStore)
            }
            if manifest.segments.allSatisfy(\.isComplete) {
                // Fully streamed already: assemble without any network fetch.
                let destination = localURL(for: id, versionId: versionId)
                try segmentedStore.assemble(manifest: manifest, destination: destination)
                lock.withLock {
                    guard probeAttempts[key]?.id == probeAttempt.id else { return }
                    probeAttempts[key] = nil
                    inFlight[key] = nil
                }
                return destination
            }
            return try await startSegmentedAttempt(
                manifest: manifest,
                bearerToken: bearerToken,
                probeAttempt: probeAttempt
            )
```

Check the surrounding code: if the existing failure path also records completion history or fires other bookkeeping (search for where `completionHistory` is appended on success), mirror what the normal completion delegate does for the all-complete shortcut — read `urlSession(_:downloadTask:didFinishDownloadingTo:)`'s segmented completion branch and reuse its post-assemble bookkeeping (there may be a shared private method; if the bookkeeping is tangled into the delegate, extract the minimal shared helper).

- [ ] **Step 7: Full test run** — `cd ios/PatataTubeKit && swift test`. Expected: all green (existing CacheManager tests still pass with the new optional param defaulted).

- [ ] **Step 8: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): seed segmented MP4 downloads from streamed bytes"`

---

### Task 10: Offline HLS download + promotion

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (path helpers, internal activity hooks, state/removal integration)
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: `HLSManifestParser`, `SegmentCache` (via `streamCache`), existing `concurrencyGate`, `MockURLProtocol` test pattern.
- Produces:
  - `public func offlineHLSDir(for id: Int, versionId: Int?) -> URL` — `{root}/hls-{id}` or `{root}/hls-{id}_v{versionId}` (matches the proxy's offline route layout from Task 8; note Task 8 used `offlineRoot` = CacheManager root).
  - `public func offlineHLSMasterURL(for id: Int, versionId: Int?) -> URL?` — the `master.m3u8` inside that dir if it exists.
  - `public func downloadHLS(id: Int, versionId: Int?, masterURL: URL, bearerToken: String?) async throws`
  - `public var videosRoot: URL { root }` — read accessor so the app can hand the proxy its `offlineRoot`.
  - Internal activity hooks in `CacheManager.swift` (private state lives there): `func beginExternalActivity(key: String, videoId: Int, versionId: Int?, totalUnits: Int64)`, `func updateExternalActivity(key: String, completedUnits: Int64)`, `func endExternalActivity(key: String)` — create/update/remove an `inFlight` accumulator so `state(for:)` reports `.downloading(progress)` and `DownloadButton` just works. Read `DownloadActivityAccumulator` (in `DownloadActivity.swift` or `CacheManager.swift`) first and drive whatever minimal fields feed `.activity.progress`; progress is reported in units of a 10_000 total (`completedUnits = done * 10_000 / assetCount`) through its existing update path.
- State integration (edits inside `CacheManager.swift`):
  - `state(for:)` (~line 270): after the `localURL` file check, add `if offlineHLSMasterURL(for: id, versionId: versionId) != nil { return .cached }`.
  - `removeCached(id:versionId:)`: also `try? fileManager.removeItem(at: offlineHLSDir(for: id, versionId: versionId))`.
  - `hasAnyCached(id:)` / `removeAllCached(id:)` / `clearAllVideos()`: include `hls-{id}*` directories (scan `root` for names with prefix `hls-\(id)` — use an exact match on `hls-\(id)` plus prefix `hls-\(id)_` to avoid id 1 matching id 12).

Download flow (in `CacheManager+HLS.swift`):

```
downloadHLS(id:versionId:masterURL:bearerToken:):
  key = cacheKey(videoId:versionId:)   ← same key state(for:) derives, so the button sees progress;
                                         a second registration while inFlight[key] exists throws (mirrors MP4)
  await concurrencyGate.acquire(); defer release
  beginExternalActivity(key:...); defer endExternalActivity on throw
  tmp = root/".hls-tmp"/{cacheKey}  (wiped at start)
  fetch master.m3u8 (authed GET, 2xx else throw APIError.badStatus)
  write to tmp/master.m3u8
  playlists = HLSManifestParser.referencedPlaylists(master)
  for each playlist p (video.m3u8, subtitles/xx.m3u8):
      fetch, write tmp/p
      assets = HLSManifestParser.mediaAssets(playlist text)
      resolve each asset relative to p's directory (subtitles/xx.m3u8 → subtitles/xx.vtt)
      append to asset list
  packageHash = SegmentCache.packageHash(video.m3u8 bytes)
  fetch assets with TaskGroup (width 3):
      cached = await streamCache?.segments.cachedData(videoId: id, hash: packageHash, asset: a)
      if cached → write to tmp/a  (byte reuse — no network)
      else fetch authed, write tmp/a
      after each: updateExternalActivity(fraction: done/total)
  verify every asset file exists in tmp
  destination = offlineHLSDir(for: id, versionId: versionId)
  remove destination if present; fileManager.moveItem(tmp → destination)
  endExternalActivity(key)
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PatataTubeKit

final class CacheManagerHLSTests: XCTestCase {
    private var root: URL!
    private var cache: CacheManager!
    private var streamCache: StreamCache!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        streamCache = StreamCache(root: root.appendingPathComponent("stream"))
        cache = CacheManager(
            root: root.appendingPathComponent("videos"),
            configuration: config,
            streamCache: streamCache
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",LANGUAGE=\"es\",NAME=\"Spanish\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subtitles/es.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nvideo.m3u8\n"
    private let media = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6.0,\nsegment_00000.m4s\n#EXT-X-ENDLIST\n"
    private let subs = "#EXTM3U\n#EXTINF:12.0,\nes.vtt\n#EXT-X-ENDLIST\n"

    func testDownloadHLSFetchesAllAssetsAndPromotes() async throws {
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: Data(master.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: Data(media.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.m3u8", data: Data(subs.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stub(path: "/videos/5/hls/segment_00000.m4s", data: Data([2]))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.vtt", data: Data([3]))

        try await cache.downloadHLS(
            id: 5, versionId: nil,
            masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
            bearerToken: "tok"
        )

        let dir = cache.offlineHLSDir(for: 5, versionId: nil)
        for asset in ["master.m3u8", "video.m3u8", "subtitles/es.m3u8",
                      "init.mp4", "segment_00000.m4s", "subtitles/es.vtt"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(asset).path),
                asset
            )
        }
        XCTAssertEqual(cache.state(for: 5), .cached)
        XCTAssertNotNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }

    func testDownloadHLSReusesStreamedSegments() async throws {
        let hash = SegmentCache.packageHash(forPlaylist: Data(media.utf8))
        try await streamCache.segments.store(
            videoId: 5, hash: hash, asset: "segment_00000.m4s", data: Data([9])
        )
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: Data(master.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: Data(media.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.m3u8", data: Data(subs.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.vtt", data: Data([3]))
        // NOTE: segment_00000.m4s deliberately NOT stubbed — a fetch would fail.

        try await cache.downloadHLS(
            id: 5, versionId: nil,
            masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
            bearerToken: "tok"
        )

        let seg = cache.offlineHLSDir(for: 5, versionId: nil)
            .appendingPathComponent("segment_00000.m4s")
        XCTAssertEqual(try Data(contentsOf: seg), Data([9])) // came from stream cache
    }

    func testRemoveCachedDeletesOfflineHLS() async throws {
        let dir = cache.offlineHLSDir(for: 5, versionId: nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("master.m3u8"))
        XCTAssertEqual(cache.state(for: 5), .cached)
        cache.removeCached(id: 5)
        XCTAssertEqual(cache.state(for: 5), .notCached)
    }

    func testFailedAssetFetchThrowsAndDoesNotPromote() async throws {
        MockURLProtocol.stub(path: "/videos/5/hls/master.m3u8", data: Data(master.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/video.m3u8", data: Data(media.utf8))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.m3u8", data: Data(subs.utf8))
        // init.mp4 missing → 404 → download must throw, nothing promoted.
        MockURLProtocol.stub(path: "/videos/5/hls/segment_00000.m4s", data: Data([2]))
        MockURLProtocol.stub(path: "/videos/5/hls/subtitles/es.vtt", data: Data([3]))

        do {
            try await cache.downloadHLS(
                id: 5, versionId: nil,
                masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
                bearerToken: "tok"
            )
            XCTFail("expected throw")
        } catch {}
        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
        XCTAssertEqual(cache.state(for: 5), .notCached)
    }
}
```

(`MockURLProtocol.stub` must return 404 for unstubbed paths — verify; that's the usual pattern. `CacheManager` init labels: match the internal init from Task 9, supplying `fileManager`/defaults as the existing tests in `CacheManagerConcurrencyGateTests.swift` do — copy their construction style.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter CacheManagerHLSTests`. Expected: compile errors.

- [ ] **Step 3: Implement**

In `CacheManager.swift` add (near `localURL`):

```swift
    /// Directory of a promoted (offline) HLS package.
    public func offlineHLSDir(for id: Int, versionId: Int? = nil) -> URL {
        let suffix = versionId.map { "_v\($0)" } ?? ""
        return root.appendingPathComponent("hls-\(id)\(suffix)", isDirectory: true)
    }

    /// The offline package's master playlist, or nil when not downloaded.
    public func offlineHLSMasterURL(for id: Int, versionId: Int? = nil) -> URL? {
        let url = offlineHLSDir(for: id, versionId: versionId).appendingPathComponent("master.m3u8")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Root of the permanent video store — handed to StreamProxy as offlineRoot.
    public var videosRoot: URL { root }

    // MARK: External activity hooks (HLS downloads live in CacheManager+HLS.swift
    // but progress state is private to this file).

    func beginExternalActivity(key: String, videoId: Int, versionId: Int?, totalUnits: Int64) {
        lock.withLock {
            inFlight[key] = DownloadActivityAccumulator(
                videoID: videoId, versionID: versionId,
                totalByteCount: totalUnits, now: now()
            )
        }
    }

    func updateExternalActivity(key: String, completedUnits: Int64) {
        lock.withLock {
            inFlight[key]?.update(received: completedUnits, now: now())
        }
    }

    func endExternalActivity(key: String) {
        lock.withLock { inFlight[key] = nil }
    }
```

(`DownloadActivityAccumulator`'s real update method name/shape: read it and adapt `updateExternalActivity` — the contract is only that `state(for:)`'s `.downloading($0.activity.progress)` moves. Also note `state(for:)` derives its key via `cacheKey(videoId:versionId:)` — the HLS activity must be registered under that same key for the button to see it, so drop the `"hls:"` prefix idea and use the plain cache key; MP4 and HLS downloads of the same video/version can't run concurrently anyway because the guard in `downloadVideo` and the `inFlight` check make the second registration fail — verify and mirror the existing "already in flight" behavior: `downloadHLS` throws `CancellationError()` when `inFlight[key] != nil`.)

Edits to `state(for:)`, `removeCached`, `hasAnyCached`, `removeAllCached`, `clearAllVideos` as listed in Interfaces above.

Create `CacheManager+HLS.swift`:

```swift
import Foundation

extension CacheManager {
    /// Downloads a full HLS package for offline playback, reusing any
    /// segments already in the stream cache, and promotes it atomically into
    /// the permanent store. Progress is visible through `state(for:)`.
    public func downloadHLS(
        id: Int,
        versionId: Int? = nil,
        masterURL: URL,
        bearerToken: String?
    ) async throws {
        let key = cacheKey(videoId: id, versionId: versionId)
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }

        let alreadyRunning = lockedInFlightExists(key: key)
        guard !alreadyRunning else { throw CancellationError() }

        beginExternalActivity(key: key, videoId: id, versionId: versionId, totalUnits: 10_000)
        var finished = false
        defer { if !finished { endExternalActivity(key: key) } }

        let tmp = videosRoot
            .appendingPathComponent(".hls-tmp", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func fetch(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        }

        func write(_ data: Data, asset: String) throws {
            let url = tmp.appendingPathComponent(asset)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        func assetURL(_ asset: String) -> URL {
            // Resolve relative to the master playlist's directory.
            var comps = URLComponents(url: masterURL, resolvingAgainstBaseURL: false)!
            let query = comps.queryItems
            comps.queryItems = nil
            let base = comps.url!.deletingLastPathComponent()
            var resolved = URLComponents(
                url: base.appendingPathComponent(asset), resolvingAgainstBaseURL: false
            )!
            resolved.queryItems = query
            return resolved.url!
        }

        // 1. Playlists.
        let masterData = try await fetch(masterURL)
        try write(masterData, asset: "master.m3u8")
        let masterText = String(decoding: masterData, as: UTF8.self)

        var assets: [String] = []
        var packageHash: String?
        for playlist in HLSManifestParser.referencedPlaylists(inMasterPlaylist: masterText) {
            let data = try await fetch(assetURL(playlist))
            try write(data, asset: playlist)
            if playlist == "video.m3u8" {
                packageHash = SegmentCache.packageHash(forPlaylist: data)
            }
            let text = String(decoding: data, as: UTF8.self)
            let playlistDir = (playlist as NSString).deletingLastPathComponent
            for media in HLSManifestParser.mediaAssets(inMediaPlaylist: text) {
                let relative = playlistDir.isEmpty ? media : "\(playlistDir)/\(media)"
                if !assets.contains(relative) { assets.append(relative) }
            }
        }

        // 2. Media assets — stream-cache hits are free, misses hit the network.
        let total = max(assets.count, 1)
        var done = 0
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var iterator = assets.makeIterator()
            var active = 0
            func addNext(_ group: inout ThrowingTaskGroup<(String, Data), Error>) {
                guard let asset = iterator.next() else { return }
                active += 1
                let hash = packageHash
                group.addTask { [streamCache] in
                    if let hash,
                       let cached = await streamCache?.segments.cachedData(
                           videoId: id, hash: hash, asset: asset
                       ) {
                        return (asset, cached)
                    }
                    return (asset, try await fetch(assetURL(asset)))
                }
            }
            for _ in 0..<3 { addNext(&group) }
            while active > 0 {
                guard let (asset, data) = try await group.next() else { break }
                active -= 1
                try write(data, asset: asset)
                done += 1
                updateExternalActivity(
                    key: key, completedUnits: Int64(done * 10_000 / total)
                )
                addNext(&group)
            }
        }

        // 3. Promote atomically.
        let destination = offlineHLSDir(for: id, versionId: versionId)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        finished = true
        endExternalActivity(key: key)
    }
}
```

`lockedInFlightExists(key:)` is a one-line internal helper in `CacheManager.swift`: `func lockedInFlightExists(key: String) -> Bool { lock.withLock { inFlight[key] != nil } }`. `fetch` uses `URLSession.shared` — wrong for tests; instead expose the manager's session: add an internal accessor in `CacheManager.swift` (`var urlSession: URLSession { session }`) and use `self.urlSession` in `fetch` so `MockURLProtocol` applies. `cacheKey(videoId:versionId:)` is an existing private func — make it internal (it's referenced from the extension file).

- [ ] **Step 4: Run to verify pass** — `swift test --filter CacheManagerHLSTests`, then full `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A ios/PatataTubeKit && git commit -m "feat(ios): offline HLS downloads reusing streamed segments"`

---

### Task 11: App wiring (proxy lifecycle, player order, download branch)

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift` (create + start proxy, pass `streamCache` to CacheManager, proxy-aware URL helpers)
- Modify: `ios/PatataTube/Sources/VideoPlayerView.swift:211-227` (`playerItem(for:)` order)
- Modify: `ios/PatataTube/Sources/VideoGridView.swift:295-320` (HLS download branch)
- Test: build only (app target has no automated tests; kit covered above)

**Interfaces:**
- Consumes: `StreamCache`, `StreamProxy`, `CacheManager(streamCache:)`, `CacheManager.downloadHLS`, `offlineHLSMasterURL`, `videosRoot`, `proxy.hlsURL/mp4URL/offlineHLSURL`.

- [ ] **Step 1: AppModel** — Read `AppModel.swift` top-to-bottom first. Apply:

```swift
    // New stored properties alongside `cache`:
    let streamCache: StreamCache
    let streamProxy: StreamProxy
```

Where `cache = CacheManager(...)` is constructed, build in order:

```swift
    let streamCache = StreamCache()
    self.streamCache = streamCache
    self.cache = CacheManager(streamCache: streamCache)   // keep existing args, add the new one
    self.streamProxy = StreamProxy(
        cache: streamCache,
        credentials: credentials,
        offlineRoot: cache.videosRoot
    )
    Task { await streamProxy.start() }
```

Add proxy-aware helpers next to `streamURL(for:)` / `hlsURL(for:)`:

```swift
    /// Proxied HLS playback URL; nil when no HLS package or proxy is down.
    func proxiedHLSURL(for video: Video) -> URL? {
        guard video.hlsPath?.isEmpty == false else { return nil }
        return streamProxy.hlsURL(videoId: video.id, versionId: video.chosenVersionId)
    }

    /// Proxied MP4 playback URL; nil when proxy is down.
    func proxiedMP4URL(for video: Video) -> URL? {
        streamProxy.mp4URL(videoId: video.id, versionId: video.chosenVersionId)
    }

    /// Offline HLS playback URL for a promoted package; nil when absent/proxy down.
    func offlineHLSURL(for video: Video) -> URL? {
        guard cache.offlineHLSMasterURL(for: video.id, versionId: video.chosenVersionId) != nil
        else { return nil }
        return streamProxy.offlineHLSURL(videoId: video.id, versionId: video.chosenVersionId)
    }
```

- [ ] **Step 2: VideoPlayerView.playerItem(for:)** — replace body with:

```swift
    private func playerItem(for video: Video) -> AVPlayerItem? {
        if model.cache.state(for: video.id, versionId: video.chosenVersionId) == .cached {
            // Offline wins: local MP4 file, else promoted HLS via the proxy.
            let local = model.cache.localURL(for: video.id, versionId: video.chosenVersionId)
            if FileManager.default.fileExists(atPath: local.path) {
                return AVPlayerItem(url: local)
            }
            if let offline = model.offlineHLSURL(for: video) {
                return AVPlayerItem(url: offline)
            }
        }
        // Library rows that haven't been converted server-side have no streamable file yet.
        if video.isLibrary && video.status != "done" { return nil }
        if let proxied = model.proxiedHLSURL(for: video) {
            // Proxied HLS: read-through cache, native subtitle tracks, no headers needed.
            return AVPlayerItem(url: proxied)
        }
        if let hlsURL = model.hlsURL(for: video) {
            // Proxy down: direct remote HLS with authed headers (old behavior).
            return AVPlayerItem(asset: authedAsset(url: hlsURL))
        }
        if video.hlsPath == nil || video.hlsPath?.isEmpty == true,
           let proxied = model.proxiedMP4URL(for: video), model.streamURL(for: video) != nil {
            // Proxied direct MP4 for rows without an HLS package.
            return AVPlayerItem(url: proxied)
        }
        if let url = model.streamURL(for: video) {
            // Proxy down: direct MP4 fallback.
            return AVPlayerItem(asset: authedAsset(url: url))
        }
        return nil
    }
```

Note the `.cached` state can now mean "offline HLS only" — the old first branch assumed a local MP4 file existed; the new branch checks explicitly.

- [ ] **Step 3: VideoGridView download branch** — in the function containing line 312 (`model.cache.download(...)`), branch on HLS availability:

```swift
        do {
            if let master = model.hlsURL(for: target), target.hlsPath?.isEmpty == false {
                try await model.cache.downloadHLS(
                    id: target.id, versionId: target.chosenVersionId,
                    masterURL: master,
                    preview: preview, showPosterKey: posterKey, showPoster: poster,
                    bearerToken: model.credentials.token
                )
            } else {
                try await model.cache.download(id: target.id, versionId: target.chosenVersionId, from: url, preview: preview,
                                               showPosterKey: posterKey, showPoster: poster,
                                               bearerToken: model.credentials.token,
                                               streamCount: model.downloadStreamCount)
            }
            return true
        }
```

`cachePreview`/`cacheShowPoster` are private on CacheManager; the cleanest route is to give `downloadHLS` the same optional `preview:`/`showPosterKey:`/`showPoster:` parameters and call the private helpers from `CacheManager+HLS.swift` after promotion, mirroring the `download(...)` wrapper exactly (they're internal to the module so the extension can call them if their access level allows; raise `private` → `internal` on `cachePreview`/`cacheShowPoster` as needed). Update the call above accordingly — final signature:

```swift
public func downloadHLS(
    id: Int, versionId: Int? = nil, masterURL: URL,
    preview: URL? = nil, showPosterKey: String? = nil, showPoster: URL? = nil,
    bearerToken: String?
) async throws
```

- [ ] **Step 4: Build the app** — `cd ios/PatataTube && xcodegen generate && xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`. Expected: build succeeds. Also rerun `cd ios/PatataTubeKit && swift test`.

- [ ] **Step 5: Commit** — `git add -A ios && git commit -m "feat(ios): wire stream proxy into player and downloads"`

---

### Task 12: Manual test checklist + final verification

**Files:**
- Modify: `ios/README.md` (manual checklist additions)

- [ ] **Step 1: Append to the manual test checklist in `ios/README.md`**

```markdown
### Stream cache / offline HLS

- [ ] Stream an HLS video partway, then tap Download — server access log shows only the *unstreamed* segments being fetched.
- [ ] Downloaded HLS video plays in airplane mode, with subtitle tracks available.
- [ ] Stream a Twitter/YouTube MP4 partway, then download — download completes and the file plays; progress starts ahead of 0% when part was streamed.
- [ ] Scrub backwards in a video you've been streaming — replay is instant (no network stall).
- [ ] Change a movie's audio language on the server, replay — new audio plays (stale segments not served).
- [ ] Delete a downloaded HLS video from Downloads — it disappears and re-streams fine.
- [ ] Kill the app mid-stream, relaunch, replay the same video — previously streamed parts don't refetch (check server log).
```

- [ ] **Step 2: Full verification** — Run: `cd ios/PatataTubeKit && swift test` and the Task 11 xcodebuild command. Expected: all green.

- [ ] **Step 3: Commit** — `git add ios/README.md && git commit -m "docs(ios): manual checklist for stream cache and offline HLS"`

- [ ] **Step 4: Finish** — Use the superpowers:finishing-a-development-branch skill (or report completion if working directly on main per user instruction).
