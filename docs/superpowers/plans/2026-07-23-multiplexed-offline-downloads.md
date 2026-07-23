# Multiplexed Offline Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download each offline MP4 through 1–4 concurrent authenticated byte
ranges, defaulting to two, while preserving aggregate progress, cancellation,
resume, legacy resume data, and the existing final cache format.

**Architecture:** A new internal `SegmentedDownload.swift` owns range math,
manifest persistence, response validation, progress arithmetic, scratch paths,
and assembly. `CacheManager` remains the public cache and URLSession-delegate
boundary, routing each task to a per-video attempt and publishing one aggregate
progress value. The SwiftUI app persists and snapshots the selected count, and
the existing FastAPI range endpoint is locked down with an explicit
recombination contract test.

**Tech Stack:** Swift 6, Foundation `URLSessionDownloadDelegate`, Swift Testing,
SwiftUI, ViewInspector, SwiftPM, XcodeGen/XCTest, Python 3.13, FastAPI, pytest.

**Spec:** `docs/superpowers/specs/2026-07-23-multiplexed-offline-downloads-design.md`

## Global Constraints

- Keep the iOS 17.0 deployment target and existing dependencies.
- Default to 2 streams and clamp persisted/configured values to `1...4`.
- Snapshot the stream count when a new video download starts.
- A manifest's stored count and ranges win when an interrupted download resumes.
- Require valid `206 Partial Content`; never fall back to a full `200` response.
- Preserve authenticated requests, versioned cache keys, final MP4 filenames,
  best-effort previews/posters, and legacy root-level `.resume` files.
- Preserve the existing foreground-only transfer model and
  `CacheState.downloading(Double)` progress ring.
- Explicit Cancel deletes all partial state and makes the next attempt start at
  zero.
- Do not add cross-video concurrency or change `DownloadButton.swift`.
- Prefix every shell command with `rtk`, per repository instructions.

---

### Task 1: Add deterministic range, manifest, validation, and assembly primitives

**Files:**

- Create:
  `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift`
- Create:
  `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`

**Interfaces:**

- Produces: `DownloadByteRange(start:end:)`, `.length`, and `.headerValue`.
- Produces:
  `DownloadByteRange.split(totalByteCount:streamCount:) throws -> [DownloadByteRange]`.
- Produces:
  `SegmentedDownloadManifest.make(videoId:versionId:remoteURL:requestedStreamCount:totalByteCount:etag:)`.
- Produces: `SegmentedDownloadStore` scratch, atomic manifest, validation,
  cleanup, progress, and assembly methods consumed by Task 2.
- Produces: `SegmentedDownloadError`, including exact invalid-contract and
  corrupt-disk cases.

- [ ] **Step 1: Write failing range and manifest tests**

Create `SegmentedDownloadTests.swift` with these first tests:

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Segmented download primitives", .serialized)
struct SegmentedDownloadTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("segments-\(UUID().uuidString)")
    }

    @Test func splitsOneThroughFourStreamsWithoutGapsOrOverlap() throws {
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 1) == [
            .init(start: 0, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 2) == [
            .init(start: 0, end: 4),
            .init(start: 5, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 3) == [
            .init(start: 0, end: 2),
            .init(start: 3, end: 5),
            .init(start: 6, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 4) == [
            .init(start: 0, end: 1),
            .init(start: 2, end: 4),
            .init(start: 5, end: 6),
            .init(start: 7, end: 9),
        ])
    }

    @Test func tinyFilesUseOnlyNonemptyRanges() throws {
        #expect(try DownloadByteRange.split(totalByteCount: 2, streamCount: 4) == [
            .init(start: 0, end: 0),
            .init(start: 1, end: 1),
        ])
        #expect(throws: SegmentedDownloadError.invalidTotalByteCount) {
            try DownloadByteRange.split(totalByteCount: 0, streamCount: 2)
        }
        #expect(throws: SegmentedDownloadError.invalidStreamCount) {
            try DownloadByteRange.split(totalByteCount: 10, streamCount: 0)
        }
        #expect(throws: SegmentedDownloadError.invalidStreamCount) {
            try DownloadByteRange.split(totalByteCount: 10, streamCount: 5)
        }
    }

    @Test func manifestRoundTripsAndKeepsOriginalCount() throws {
        let store = SegmentedDownloadStore(root: root())
        let manifest = try SegmentedDownloadManifest.make(
            videoId: 17,
            versionId: 3,
            remoteURL: URL(string: "https://srv.test/videos/17/stream?version_id=3")!,
            requestedStreamCount: 4,
            totalByteCount: 11,
            etag: "\"v17\""
        )

        try store.write(manifest)
        let loaded = try store.load(cacheKey: "17:3")

        #expect(loaded == manifest)
        #expect(loaded.requestedStreamCount == 4)
        #expect(loaded.effectiveStreamCount == 4)
        #expect(loaded.segments.map(\.range) == [
            .init(start: 0, end: 1),
            .init(start: 2, end: 4),
            .init(start: 5, end: 7),
            .init(start: 8, end: 10),
        ])
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the expected compile failure**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter SegmentedDownloadTests
```

Expected: compilation fails because `DownloadByteRange`,
`SegmentedDownloadManifest`, `SegmentedDownloadStore`, and
`SegmentedDownloadError` do not exist.

- [ ] **Step 3: Implement range and manifest types**

Create `SegmentedDownload.swift` with these exact public-to-module types and
range formula. Keep every declaration `internal` (the default):

```swift
import Foundation

enum SegmentedDownloadError: Error, Equatable {
    case invalidStreamCount
    case invalidTotalByteCount
    case invalidProbe
    case invalidSegmentResponse(index: Int)
    case changedEntity
    case lengthMismatch(expected: Int64, actual: Int64)
    case corruptManifest
    case missingSegment(index: Int)
}

struct DownloadByteRange: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }
    var headerValue: String { "bytes=\(start)-\(end)" }

    static func split(
        totalByteCount: Int64,
        streamCount: Int
    ) throws -> [DownloadByteRange] {
        guard totalByteCount > 0 else {
            throw SegmentedDownloadError.invalidTotalByteCount
        }
        guard (1...4).contains(streamCount) else {
            throw SegmentedDownloadError.invalidStreamCount
        }
        let count = min(Int64(streamCount), totalByteCount)
        let quotient = totalByteCount / count
        let remainder = totalByteCount % count

        func boundary(_ index: Int64) -> Int64 {
            quotient * index + (remainder * index) / count
        }

        return (0..<count).map { index in
            DownloadByteRange(
                start: boundary(index),
                end: boundary(index + 1) - 1
            )
        }
    }
}

struct DownloadSegmentRecord: Codable, Equatable, Sendable {
    let index: Int
    let range: DownloadByteRange
    var isComplete: Bool
    var persistedByteCount: Int64
}

struct SegmentedDownloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let allowedStreamCounts = 1...4

    let schemaVersion: Int
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL
    let requestedStreamCount: Int
    let effectiveStreamCount: Int
    let totalByteCount: Int64
    let etag: String
    var segments: [DownloadSegmentRecord]

    var cacheKey: String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    static func make(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        requestedStreamCount: Int,
        totalByteCount: Int64,
        etag: String
    ) throws -> SegmentedDownloadManifest {
        let ranges = try DownloadByteRange.split(
            totalByteCount: totalByteCount,
            streamCount: requestedStreamCount
        )
        return SegmentedDownloadManifest(
            schemaVersion: currentSchemaVersion,
            videoId: videoId,
            versionId: versionId,
            remoteURL: remoteURL,
            requestedStreamCount: requestedStreamCount,
            effectiveStreamCount: ranges.count,
            totalByteCount: totalByteCount,
            etag: etag,
            segments: ranges.enumerated().map {
                DownloadSegmentRecord(
                    index: $0.offset,
                    range: $0.element,
                    isComplete: false,
                    persistedByteCount: 0
                )
            }
        )
    }

    func validated() throws -> SegmentedDownloadManifest {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.allowedStreamCounts.contains(requestedStreamCount),
              effectiveStreamCount == segments.count,
              effectiveStreamCount <= requestedStreamCount,
              totalByteCount > 0,
              !etag.isEmpty,
              !etag.hasPrefix("W/"),
              segments.map(\.index) == Array(segments.indices),
              segments.first?.range.start == 0,
              segments.last?.range.end == totalByteCount - 1,
              segments.allSatisfy({
                  $0.range.start >= 0
                      && $0.range.end >= $0.range.start
                      && $0.persistedByteCount >= 0
                      && $0.persistedByteCount <= $0.range.length
              })
        else { throw SegmentedDownloadError.corruptManifest }

        for pair in zip(segments, segments.dropFirst()) {
            guard pair.0.range.end + 1 == pair.1.range.start else {
                throw SegmentedDownloadError.corruptManifest
            }
        }
        return self
    }
}

struct DownloadProbe: Equatable, Sendable {
    let totalByteCount: Int64
    let etag: String
}
```

- [ ] **Step 4: Add failing validation, progress, cleanup, and assembly tests**

Append these tests to `SegmentedDownloadTests`:

```swift
@Test func validatesProbeAndRejectsAFullResponse() throws {
    let url = URL(string: "https://srv.test/video")!
    let valid = HTTPURLResponse(
        url: url,
        statusCode: 206,
        httpVersion: nil,
        headerFields: [
            "Accept-Ranges": "bytes",
            "Content-Range": "bytes 0-0/10",
            "Content-Length": "1",
            "ETag": "\"v1\"",
        ]
    )!
    #expect(try SegmentedDownloadStore.validateProbe(valid, bodyCount: 1)
            == DownloadProbe(totalByteCount: 10, etag: "\"v1\""))

    let full = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Length": "10", "ETag": "\"v1\""]
    )!
    #expect(throws: SegmentedDownloadError.invalidProbe) {
        try SegmentedDownloadStore.validateProbe(full, bodyCount: 10)
    }
}

@Test func aggregateProgressCountsCompletedAndPartialBytesOnce() throws {
    var manifest = try SegmentedDownloadManifest.make(
        videoId: 8,
        versionId: nil,
        remoteURL: URL(string: "https://srv.test/video")!,
        requestedStreamCount: 2,
        totalByteCount: 10,
        etag: "\"v1\""
    )
    manifest.segments[0].isComplete = true
    manifest.segments[0].persistedByteCount = 5
    manifest.segments[1].persistedByteCount = 2

    #expect(SegmentedDownloadStore.progress(
        manifest: manifest,
        activeByteCounts: [1: 3]
    ) == 0.8)
    #expect(SegmentedDownloadStore.progress(
        manifest: manifest,
        activeByteCounts: [1: 99]
    ) == 1)
}

@Test func assemblesCompletedPartsInIndexOrderAndCleansScratch() throws {
    let root = root()
    let store = SegmentedDownloadStore(root: root)
    var manifest = try SegmentedDownloadManifest.make(
        videoId: 9,
        versionId: 2,
        remoteURL: URL(string: "https://srv.test/video")!,
        requestedStreamCount: 3,
        totalByteCount: 6,
        etag: "\"v1\""
    )
    try store.write(manifest)
    for index in manifest.segments.indices {
        manifest.segments[index].isComplete = true
        let bytes = Data(repeating: UInt8(index + 1), count: 2)
        try bytes.write(to: store.partURL(cacheKey: manifest.cacheKey, index: index))
    }
    try store.write(manifest)

    let destination = root.appendingPathComponent("9.v2.mp4")
    try store.assemble(manifest: manifest, destination: destination)

    #expect(try Data(contentsOf: destination) == Data([1, 1, 2, 2, 3, 3]))
    #expect(!FileManager.default.fileExists(
        atPath: store.directory(cacheKey: manifest.cacheKey).path
    ))
}
```

- [ ] **Step 5: Implement the disk store and validators**

Add `SegmentedDownloadStore` to `SegmentedDownload.swift`. Use atomic manifest
writes and bounded response checks:

```swift
struct SegmentedDownloadStore: Sendable {
    let root: URL
    private let fileManager = FileManager.default

    private var downloadsRoot: URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
    }

    func directory(cacheKey: String) -> URL {
        downloadsRoot.appendingPathComponent(cacheKey, isDirectory: true)
    }

    func manifestURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("manifest.json")
    }

    func partURL(cacheKey: String, index: Int) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("segment-\(index).part")
    }

    func resumeURL(cacheKey: String, index: Int) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("segment-\(index).resume")
    }

    func assemblyURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("assembled.tmp")
    }

    func write(_ manifest: SegmentedDownloadManifest) throws {
        _ = try manifest.validated()
        let directory = directory(cacheKey: manifest.cacheKey)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(cacheKey: manifest.cacheKey), options: .atomic)
    }

    func load(cacheKey: String) throws -> SegmentedDownloadManifest {
        do {
            let data = try Data(contentsOf: manifestURL(cacheKey: cacheKey))
            return try JSONDecoder().decode(
                SegmentedDownloadManifest.self,
                from: data
            ).validated()
        } catch let error as SegmentedDownloadError {
            throw error
        } catch {
            throw SegmentedDownloadError.corruptManifest
        }
    }

    func manifests() -> [SegmentedDownloadManifest] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: downloadsRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        return directories.compactMap { directory in
            let key = directory.lastPathComponent
            do {
                return try load(cacheKey: key)
            } catch {
                remove(cacheKey: key)
                return nil
            }
        }
    }

    func remove(cacheKey: String) {
        try? fileManager.removeItem(at: directory(cacheKey: cacheKey))
    }

    static func validateProbe(
        _ response: HTTPURLResponse,
        bodyCount: Int
    ) throws -> DownloadProbe {
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              response.value(forHTTPHeaderField: "Content-Length") == "1",
              bodyCount == 1,
              let etag = response.value(forHTTPHeaderField: "ETag"),
              !etag.isEmpty,
              !etag.hasPrefix("W/"),
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0
        else { throw SegmentedDownloadError.invalidProbe }
        return DownloadProbe(totalByteCount: total, etag: etag)
    }

    static func validateSegment(
        _ response: HTTPURLResponse,
        planned: DownloadSegmentRecord,
        etag: String,
        totalByteCount: Int64,
        fileSize: Int64,
        resumed: Bool
    ) throws {
        guard response.statusCode == 206 else {
            if (400..<600).contains(response.statusCode) {
                throw APIError.badStatus(response.statusCode)
            }
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
        guard response.value(forHTTPHeaderField: "ETag") == etag else {
            throw SegmentedDownloadError.changedEntity
        }
        guard fileSize == planned.range.length else {
            throw SegmentedDownloadError.lengthMismatch(
                expected: planned.range.length,
                actual: fileSize
            )
        }
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = parseContentRange(value),
              parsed.totalByteCount == totalByteCount,
              response.value(forHTTPHeaderField: "Content-Length")
                == "\(parsed.range.length)"
        else {
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
        let validRange = resumed
            ? parsed.range.start >= planned.range.start
                && parsed.range.end == planned.range.end
                && parsed.range.start <= parsed.range.end
            : parsed.range == planned.range
        guard validRange else {
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
    }

    static func progress(
        manifest: SegmentedDownloadManifest,
        activeByteCounts: [Int: Int64]
    ) -> Double {
        let received = manifest.segments.reduce(Int64(0)) { total, segment in
            let active = activeByteCounts[segment.index] ?? 0
            let bytes = segment.isComplete
                ? segment.range.length
                : min(segment.range.length, segment.persistedByteCount + active)
            return total + bytes
        }
        return min(max(Double(received) / Double(manifest.totalByteCount), 0), 1)
    }

    func assemble(
        manifest: SegmentedDownloadManifest,
        destination: URL
    ) throws {
        let validated = try manifest.validated()
        guard validated.segments.allSatisfy(\.isComplete) else {
            throw SegmentedDownloadError.corruptManifest
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let assembly = assemblyURL(cacheKey: validated.cacheKey)
        fileManager.createFile(atPath: assembly.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: assembly)
            defer { try? output.close() }

            for segment in validated.segments {
                let part = partURL(cacheKey: validated.cacheKey, index: segment.index)
                guard fileManager.fileExists(atPath: part.path) else {
                    throw SegmentedDownloadError.missingSegment(index: segment.index)
                }
                let attributes = try fileManager.attributesOfItem(atPath: part.path)
                let partSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard partSize == segment.range.length else {
                    throw SegmentedDownloadError.lengthMismatch(
                        expected: segment.range.length,
                        actual: partSize
                    )
                }
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576),
                      !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
        }

        let attributes = try fileManager.attributesOfItem(atPath: assembly.path)
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == validated.totalByteCount else {
            throw SegmentedDownloadError.lengthMismatch(
                expected: validated.totalByteCount,
                actual: actual
            )
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: assembly, to: destination)
        remove(cacheKey: validated.cacheKey)
    }

    private struct ParsedContentRange {
        let range: DownloadByteRange
        let totalByteCount: Int64
    }

    private static func parseContentRange(_ value: String) -> ParsedContentRange? {
        guard value.hasPrefix("bytes "),
              let slash = value.firstIndex(of: "/"),
              let total = Int64(value[value.index(after: slash)...])
        else { return nil }
        let interval = value[value.index(value.startIndex, offsetBy: 6)..<slash]
        let parts = interval.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1])
        else { return nil }
        return ParsedContentRange(
            range: DownloadByteRange(start: start, end: end),
            totalByteCount: total
        )
    }
}
```

- [ ] **Step 6: Run the primitive suite and the complete Kit suite**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter SegmentedDownloadTests
rtk test swift test
```

Expected: all primitive tests and all pre-existing PatataTubeKit tests pass.

- [ ] **Step 7: Commit the primitives**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift
rtk git add ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift
rtk git commit -m "feat(ios): add segmented download primitives"
```

### Task 2: Download and assemble fresh ranges concurrently

**Files:**

- Modify:
  `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Modify:
  `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**

- Changes:
  `download(id:versionId:from:preview:showPosterKey:showPoster:bearerToken:streamCount:)`.
- Produces one `SegmentedAttempt` per cache key and one
  `SegmentTaskContext` per URLSession task identifier.
- Consumes every range/manifest/store interface from Task 1.
- Preserves the current preview/poster sequence after the MP4 succeeds.

- [ ] **Step 1: Replace the basic mock with a range-aware protocol**

In `CacheManagerTests.swift`, replace `MockDownloadProtocol` with a serialized
range-aware mock. It must record requests under a lock because segment requests
arrive concurrently:

```swift
private final class RangeDownloadProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var payload = Data("0123456789".utf8)
    nonisolated(unsafe) static var etag = "\"test-video\""
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var delayByRange: [String: TimeInterval] = [:]
    nonisolated(unsafe) static var responseOverride:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset(payload: Data = Data("0123456789".utf8)) {
        lock.withLock {
            self.payload = payload
            etag = "\"test-video\""
            requests = []
            delayByRange = [:]
            responseOverride = nil
        }
    }

    static func setDelays(_ delays: [String: TimeInterval]) {
        lock.withLock { delayByRange = delays }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.lock.withLock {
                Self.requests.append(request)
                if let responseOverride = Self.responseOverride {
                    return try responseOverride(request)
                }
                return try Self.response(for: request)
            }
            let delay = Self.lock.withLock {
                Self.delayByRange[
                    request.value(forHTTPHeaderField: "Range") ?? ""
                ] ?? 0
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func response(
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        if request.value(forHTTPHeaderField: "Range") == nil {
            let data = Data([0xAA, 0xBB])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(data.count)"]
                )!,
                data
            )
        }
        guard let header = request.value(forHTTPHeaderField: "Range"),
              header.hasPrefix("bytes=")
        else { throw URLError(.badServerResponse) }
        let parts = header.dropFirst("bytes=".count).split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]),
              start >= 0,
              end >= start,
              end < payload.count
        else { throw URLError(.badServerResponse) }
        let body = payload.subdata(in: start..<(end + 1))
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                    "Content-Length": "\(body.count)",
                    "ETag": etag,
                ]
            )!,
            body
        )
    }
}

private func rangeDownloadConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RangeDownloadProtocol.self]
    return config
}
```

Also add `HangingRangeProtocol` in this step. It returns a valid
`206 bytes 0-0/12` probe immediately, then sends one byte for every other valid
range and deliberately never calls `urlProtocolDidFinishLoading`. Add
`hangingRangeConfig()` using that protocol. Change the fresh segmented
`cancelThrowsAndReturnsToNotCached` test to use this configuration; retain the
old `HangingDownloadProtocol` only for opaque legacy-resume tests.

```swift
private final class HangingRangeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=")
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Data([UInt8(start % 255)])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(start)-\(end)/12",
                "Content-Length": "\(end - start + 1)",
                "ETag": "\"hanging\"",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if start == 0 && end == 0 {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private func hangingRangeConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HangingRangeProtocol.self]
    return config
}
```

Make `CancelThenRetryDownloadProtocol` range-aware: each attempt's
`bytes=0-0` probe returns a complete valid probe; the first non-probe request
hangs until cancelled, and the retry's non-probe request waits until the first
instance stops before returning its valid `206` body. Preserve the existing
condition-variable assertions.

Update existing success, preview, poster, bearer-token, and bad-status tests to
use `rangeDownloadConfig()`. Call `RangeDownloadProtocol.reset(...)` at the
start of each affected test. Change video-byte expectations to the mock's full
payload. For the bearer-token test, expect the probe, segment, and preview
requests all to carry `Bearer secret`.

- [ ] **Step 2: Add failing fresh-multiplex tests**

Add these tests to `CacheManagerTests`:

```swift
@Test func fourStreamsSendExactRangesAndAssembleOriginalBytes() async throws {
    let payload = Data((0..<23).map { UInt8($0) })
    RangeDownloadProtocol.reset(payload: payload)
    RangeDownloadProtocol.setDelays([
        "bytes=0-4": 0.04,
        "bytes=5-10": 0.03,
        "bytes=11-16": 0.02,
        "bytes=17-22": 0.01,
    ])
    let root = tempRoot()
    let manager = CacheManager(root: root, configuration: rangeDownloadConfig())

    try await manager.download(
        id: 50,
        from: URL(string: "https://srv.test/videos/50/stream")!,
        bearerToken: "secret",
        streamCount: 4
    )

    let ranges = RangeDownloadProtocol.recordedRequests().compactMap {
        $0.value(forHTTPHeaderField: "Range")
    }
    #expect(ranges.first == "bytes=0-0")
    #expect(Set(ranges.dropFirst()) == Set([
        "bytes=0-4",
        "bytes=5-10",
        "bytes=11-16",
        "bytes=17-22",
    ]))
    let segmentRequests = RangeDownloadProtocol.recordedRequests().dropFirst()
    #expect(segmentRequests.allSatisfy {
        $0.value(forHTTPHeaderField: "If-Range") == "\"test-video\""
    })
    #expect(segmentRequests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
    })
    #expect(try Data(contentsOf: manager.localURL(for: 50)) == payload)
    #expect(manager.state(for: 50) == .cached)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".downloads/50").path
    ))
}

@Test func rejectsServerThatIgnoresRangesWithoutPublishingAFile() async {
    RangeDownloadProtocol.reset()
    RangeDownloadProtocol.responseOverride = { request in
        let data = Data("full body".utf8)
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!,
            data
        )
    }
    let manager = CacheManager(root: tempRoot(), configuration: rangeDownloadConfig())

    await #expect(throws: SegmentedDownloadError.invalidProbe) {
        try await manager.download(
            id: 51,
            from: URL(string: "https://srv.test/videos/51/stream")!,
            streamCount: 2
        )
    }
    #expect(manager.state(for: 51) == .notCached)
    #expect(!FileManager.default.fileExists(atPath: manager.localURL(for: 51).path))
}
```

- [ ] **Step 3: Run the new tests and verify failure**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter CacheManagerTests.fourStreamsSendExactRanges
rtk test swift test --filter CacheManagerTests.rejectsServerThatIgnoresRanges
```

Expected: the first test fails to compile because `streamCount` does not exist;
the second test still follows the old full-download behavior.

- [ ] **Step 4: Add per-attempt state and the new API parameter**

In `CacheManager.swift`, add these private types above the class:

```swift
private struct SegmentTaskContext {
    let attemptID: UUID
    let cacheKey: String
    let segmentIndex: Int
    let resumed: Bool
}

private final class SegmentedAttempt {
    let id = UUID()
    let cacheKey: String
    var manifest: SegmentedDownloadManifest
    var continuation: CheckedContinuation<URL, Error>?
    var taskIDs: Set<Int> = []
    var activeByteCounts: [Int: Int64] = [:]
    var completedResults: [Int: Result<URL, Error>] = [:]
    var terminalError: Error?
    var explicitlyCancelled = false

    init(
        cacheKey: String,
        manifest: SegmentedDownloadManifest,
        continuation: CheckedContinuation<URL, Error>?
    ) {
        self.cacheKey = cacheKey
        self.manifest = manifest
        self.continuation = continuation
    }
}
```

Add these `CacheManager` properties without deleting the legacy single-task
maps yet:

```swift
private let segmentedStore: SegmentedDownloadStore
private var segmentedAttempts: [String: SegmentedAttempt] = [:]
private var segmentContextByTask: [Int: SegmentTaskContext] = [:]
private var tasksByIdentifier: [Int: URLSessionDownloadTask] = [:]
```

Initialize `segmentedStore` from `self.root` before `super.init()`.

Add `streamCount: Int = 1` as the final parameter of `download(...)`, clamp it
to at least one, and pass it into `downloadVideo(...)`:

```swift
public func download(
    id: Int,
    versionId: Int? = nil,
    from remote: URL,
    preview: URL? = nil,
    showPosterKey: String? = nil,
    showPoster: URL? = nil,
    bearerToken: String? = nil,
    streamCount: Int = 1
) async throws {
    _ = try await downloadVideo(
        id: id,
        versionId: versionId,
        from: remote,
        bearerToken: bearerToken,
        streamCount: min(max(streamCount, 1), 4)
    )
    if let preview {
        try? await cachePreview(id: id, from: preview, bearerToken: bearerToken)
    }
    if let showPosterKey,
       let showPoster,
       cachedShowPosterURL(for: showPosterKey) == nil {
        try? await cacheShowPoster(
            key: showPosterKey,
            from: showPoster,
            bearerToken: bearerToken
        )
    }
}
```

- [ ] **Step 5: Implement probe, attempt registration, and task creation**

Replace the fresh (non-legacy-resume) branch of `downloadVideo` with:

```swift
private func downloadVideo(
    id: Int,
    versionId: Int?,
    from remote: URL,
    bearerToken: String?,
    streamCount: Int
) async throws -> URL {
    let key = cacheKey(videoId: id, versionId: versionId)

    if let data = try? Data(contentsOf: resumeURL(for: key)), !data.isEmpty {
        return try await downloadLegacy(
            key: key,
            resumeData: data
        )
    }

    lock.withLock { inFlight[key] = 0 }
    do {
        let probe = try await probe(remote: remote, bearerToken: bearerToken)
        let manifest = try SegmentedDownloadManifest.make(
            videoId: id,
            versionId: versionId,
            remoteURL: remote,
            requestedStreamCount: streamCount,
            totalByteCount: probe.totalByteCount,
            etag: probe.etag
        )
        try segmentedStore.write(manifest)
        return try await startSegmentedAttempt(
            manifest: manifest,
            bearerToken: bearerToken
        )
    } catch {
        lock.withLock { inFlight[key] = nil }
        segmentedStore.remove(cacheKey: key)
        throw error
    }
}

private func probe(
    remote: URL,
    bearerToken: String?
) async throws -> DownloadProbe {
    var request = URLRequest(url: remote)
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    if let bearerToken {
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw SegmentedDownloadError.invalidProbe
    }
    if (400..<600).contains(http.statusCode) {
        throw APIError.badStatus(http.statusCode)
    }
    return try SegmentedDownloadStore.validateProbe(http, bodyCount: data.count)
}

private func startSegmentedAttempt(
    manifest: SegmentedDownloadManifest,
    bearerToken: String?
) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
        let attempt = SegmentedAttempt(
            cacheKey: manifest.cacheKey,
            manifest: manifest,
            continuation: continuation
        )
        lock.withLock {
            segmentedAttempts[manifest.cacheKey] = attempt
            inFlight[manifest.cacheKey] = SegmentedDownloadStore.progress(
                manifest: manifest,
                activeByteCounts: [:]
            )
        }
        startIncompleteSegments(attempt: attempt, bearerToken: bearerToken)
    }
}

private func startIncompleteSegments(
    attempt: SegmentedAttempt,
    bearerToken: String?
) {
    for segment in attempt.manifest.segments where !segment.isComplete {
        var request = URLRequest(url: attempt.manifest.remoteURL)
        request.setValue(segment.range.headerValue, forHTTPHeaderField: "Range")
        request.setValue(attempt.manifest.etag, forHTTPHeaderField: "If-Range")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let task = session.downloadTask(with: request)
        let context = SegmentTaskContext(
            attemptID: attempt.id,
            cacheKey: attempt.cacheKey,
            segmentIndex: segment.index,
            resumed: false
        )
        lock.withLock {
            attempt.taskIDs.insert(task.taskIdentifier)
            segmentContextByTask[task.taskIdentifier] = context
            tasksByIdentifier[task.taskIdentifier] = task
        }
        task.resume()
    }
}
```

Extract the current single-task continuation path into
`downloadLegacy(key:resumeData:)` without changing its delegate behavior.
Only a pre-existing root-level `.resume` calls it.

- [ ] **Step 6: Route delegate progress and completion to segmented attempts**

At the top of each URLSession delegate method, look up
`segmentContextByTask[taskIdentifier]`. If present, call the segmented helper
and return; otherwise execute the existing legacy body.

Use these helper contracts:

```swift
private func updateSegmentProgress(
    context: SegmentTaskContext,
    bytesWritten: Int64
)

private func recordSegmentFile(
    context: SegmentTaskContext,
    task: URLSessionDownloadTask,
    location: URL
) -> Result<URL, Error>

private func completeSegmentTask(
    context: SegmentTaskContext,
    taskIdentifier: Int,
    error: Error?
)

private func finishSegmentedAttempt(
    _ attempt: SegmentedAttempt,
    result: Result<URL, Error>
)
```

Implement them with these exact state transitions:

```swift
private func updateSegmentProgress(
    context: SegmentTaskContext,
    bytesWritten: Int64
) {
    lock.withLock {
        guard let attempt = segmentedAttempts[context.cacheKey],
              attempt.id == context.attemptID
        else { return }
        attempt.activeByteCounts[context.segmentIndex, default: 0]
            += max(bytesWritten, 0)
        inFlight[context.cacheKey] = SegmentedDownloadStore.progress(
            manifest: attempt.manifest,
            activeByteCounts: attempt.activeByteCounts
        )
    }
}

private func recordSegmentFile(
    context: SegmentTaskContext,
    task: URLSessionDownloadTask,
    location: URL
) -> Result<URL, Error> {
    guard let attempt = lock.withLock({
        segmentedAttempts[context.cacheKey].flatMap {
            $0.id == context.attemptID ? $0 : nil
        }
    }) else {
        return .failure(CancellationError())
    }
    do {
        guard let response = task.response as? HTTPURLResponse else {
            throw SegmentedDownloadError.invalidSegmentResponse(
                index: context.segmentIndex
            )
        }
        let record = attempt.manifest.segments[context.segmentIndex]
        let size = ((try FileManager.default.attributesOfItem(
            atPath: location.path
        )[.size]) as? NSNumber)?.int64Value ?? -1
        try SegmentedDownloadStore.validateSegment(
            response,
            planned: record,
            etag: attempt.manifest.etag,
            totalByteCount: attempt.manifest.totalByteCount,
            fileSize: size,
            resumed: context.resumed
        )
        let part = segmentedStore.partURL(
            cacheKey: context.cacheKey,
            index: context.segmentIndex
        )
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: location, to: part)
        return .success(part)
    } catch {
        return .failure(error)
    }
}
```

On successful `didCompleteWithError(nil)`, mark the matching manifest segment
complete, set its persisted count to the planned length, delete its `.resume`,
write the manifest atomically, and remove the task ID. When all records are
complete, call `segmentedStore.assemble(...)` and finish the continuation.

On any Task 2 error, cancel sibling tasks, discard segmented scratch, and finish
once with the original error. Task 3 replaces that discard behavior for
resumable transport failures.

Route explicit cancellation to the segmented task map now so the pre-existing
cancel and immediate-retry tests remain green:

```swift
public func cancel(id: Int, versionId: Int? = nil) {
    let key = cacheKey(videoId: id, versionId: versionId)
    let segmented = lock.withLock {
        segmentedAttempts[key].map { attempt in
            (
                attempt,
                attempt.taskIDs.compactMap { tasksByIdentifier[$0] }
            )
        }
    }
    if let (attempt, tasks) = segmented {
        finishSegmentedAttempt(
            attempt,
            result: .failure(CancellationError())
        )
        segmentedStore.remove(cacheKey: key)
        tasks.forEach { $0.cancel() }
    }
    lock.withLock({ tasksByKey[key] })?.cancel()
}
```

Every segmented completion path removes its identifier from
`tasksByIdentifier`, `segmentContextByTask`, and the owning attempt's
`taskIDs`. `finishSegmentedAttempt` removes the attempt and its `inFlight`
entry, then resumes and clears its continuation exactly once.

- [ ] **Step 7: Run focused and complete Kit tests**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter CacheManagerTests
rtk test swift test
```

Expected: the four-stream assembly, strict no-fallback behavior, and all
existing cache/preview/poster tests pass.

- [ ] **Step 8: Commit fresh multiplexing**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
rtk git add ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
rtk git commit -m "feat(ios): multiplex fresh offline downloads"
```

### Task 3: Preserve segment progress across interruption and cancellation

**Files:**

- Modify:
  `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Modify:
  `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`
- Modify:
  `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`

**Interfaces:**

- Changes:
  `resumeInterrupted(bearerToken: String? = nil) -> [Int]`.
- Resumes manifests with stored boundaries and only incomplete segments.
- Continues to resume legacy root-level `.resume` files as one task.
- Makes explicit `cancel(id:versionId:)` delete segmented scratch.
- Makes `removeAllCached(id:)` remove every matching scratch directory.

- [ ] **Step 1: Add failing manifest-resume and cleanup tests**

Add a store-level test proving completed parts survive and stored ranges do not
change:

```swift
@Test func storedManifestKeepsOriginalRangesAfterPreferenceChanges() throws {
    let store = SegmentedDownloadStore(root: root())
    var manifest = try SegmentedDownloadManifest.make(
        videoId: 61,
        versionId: nil,
        remoteURL: URL(string: "https://srv.test/videos/61/stream")!,
        requestedStreamCount: 3,
        totalByteCount: 12,
        etag: "\"stable\""
    )
    manifest.segments[0].isComplete = true
    manifest.segments[0].persistedByteCount = 4
    try store.write(manifest)
    try Data(repeating: 0xAA, count: 4).write(
        to: store.partURL(cacheKey: "61", index: 0)
    )
    try store.write(manifest)

    let loaded = try store.load(cacheKey: "61")

    #expect(loaded.requestedStreamCount == 3)
    #expect(loaded.segments.map(\.range) == manifest.segments.map(\.range))
    #expect(loaded.segments[0].isComplete)
}
```

Add CacheManager tests using a prewritten manifest with segment 0 completed:

```swift
@Test func resumeInterruptedRequestsOnlyIncompleteManifestSegments() async throws {
    let payload = Data("abcdefghijkl".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    let root = tempRoot()
    let store = SegmentedDownloadStore(root: root)
    var manifest = try SegmentedDownloadManifest.make(
        videoId: 62,
        versionId: nil,
        remoteURL: URL(string: "https://srv.test/videos/62/stream")!,
        requestedStreamCount: 3,
        totalByteCount: 12,
        etag: "\"test-video\""
    )
    manifest.segments[0].isComplete = true
    manifest.segments[0].persistedByteCount = 4
    try store.write(manifest)
    try payload.subdata(in: 0..<4).write(to: store.partURL(cacheKey: "62", index: 0))
    try store.write(manifest)
    let manager = CacheManager(root: root, configuration: rangeDownloadConfig())

    #expect(manager.resumeInterrupted(bearerToken: "secret") == [62])

    for _ in 0..<500 where manager.state(for: 62) != .cached {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(manager.state(for: 62) == .cached)
    let ranges = RangeDownloadProtocol.recordedRequests().compactMap {
        $0.value(forHTTPHeaderField: "Range")
    }
    #expect(!ranges.contains("bytes=0-3"))
    #expect(Set(ranges) == Set(["bytes=4-7", "bytes=8-11"]))
    #expect(try Data(contentsOf: manager.localURL(for: 62)) == payload)
}

@Test func explicitCancelRemovesSegmentedScratchAndRetryStartsFresh() async {
    let root = tempRoot()
    let manager = CacheManager(root: root, configuration: hangingRangeConfig())
    let task = Task {
        try await manager.download(
            id: 63,
            from: URL(string: "https://srv.test/videos/63/stream")!,
            streamCount: 3
        )
    }
    while manager.state(for: 63) == .notCached { await Task.yield() }

    manager.cancel(id: 63)

    await #expect(throws: Error.self) { try await task.value }
    #expect(manager.state(for: 63) == .notCached)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".downloads/63").path
    ))
}
```

Implement `HangingRangeProtocol` like the existing hanging protocol, but return
a valid `206 bytes 0-0/12` probe immediately and hold every other ranged
response open after sending at least one byte.

- [ ] **Step 2: Run focused tests and verify failure**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter CacheManagerTests.resumeInterruptedRequestsOnly
rtk test swift test --filter CacheManagerTests.explicitCancelRemovesSegmented
```

Expected: the first test fails because `resumeInterrupted` does not discover
manifests or accept a token; the second leaves or mishandles scratch state.

- [ ] **Step 3: Start manifest-backed attempts without a continuation**

At the start of `downloadVideo`, after the legacy root-level `.resume` check
and before issuing a new probe, resume a segmented manifest for the same key:

```swift
let manifestURL = segmentedStore.manifestURL(cacheKey: key)
if fileManager.fileExists(atPath: manifestURL.path) {
    do {
        let manifest = try segmentedStore.load(cacheKey: key)
        return try await startSegmentedAttempt(
            manifest: manifest,
            bearerToken: bearerToken
        )
    } catch {
        segmentedStore.remove(cacheKey: key)
        lock.withLock { inFlight[key] = nil }
        throw error
    }
}
```

This path deliberately ignores the newly supplied `streamCount`; the stored
manifest owns the interrupted attempt's original boundaries.

Change the public method signature:

```swift
@discardableResult
public func resumeInterrupted(bearerToken: String? = nil) -> [Int]
```

At the start of the method, iterate `segmentedStore.manifests()`:

```swift
for manifest in segmentedStore.manifests() {
    let key = manifest.cacheKey
    let destination = localURL(
        for: manifest.videoId,
        versionId: manifest.versionId
    )
    if fileManager.fileExists(atPath: destination.path) {
        segmentedStore.remove(cacheKey: key)
        continue
    }
    if lock.withLock({ segmentedAttempts[key] != nil || tasksByKey[key] != nil }) {
        continue
    }
    let attempt = SegmentedAttempt(
        cacheKey: key,
        manifest: manifest,
        continuation: nil
    )
    lock.withLock {
        segmentedAttempts[key] = attempt
        inFlight[key] = SegmentedDownloadStore.progress(
            manifest: manifest,
            activeByteCounts: [:]
        )
    }
    startIncompleteSegments(attempt: attempt, bearerToken: bearerToken)
    resumed.append(manifest.videoId)
}
```

Then retain the current root-level `.resume` scan for legacy data. Deduplicate
the returned IDs while preserving discovery order.

Update `startIncompleteSegments` so an incomplete segment with non-empty
`segment-i.resume` uses `session.downloadTask(withResumeData:)` and records
`resumed: true`; otherwise it creates the exact original Range request.

- [ ] **Step 4: Persist resumable failures and quiesce siblings**

Add to `SegmentedAttempt`:

```swift
var preservingResumeData = false
var resumeDataPendingTaskIDs: Set<Int> = []
```

When `didCompleteWithError` receives a transport error:

1. Save non-empty `NSURLSessionDownloadTaskResumeData` to the failing segment's
   deterministic resume URL with `.atomic`.
2. Copy that segment's most recent active byte count into
   `persistedByteCount`, clamped to its planned length.
3. Record the first error in `terminalError`.
4. Mark `preservingResumeData = true`.
5. For every still-running sibling, call
   `cancel(byProducingResumeData:)`; atomically save returned bytes to its
   deterministic resume URL and update its persisted count.
6. Remove each task from `taskIDs` only from its delegate completion, so the
   attempt cannot finish before all task callbacks settle.
7. Once `taskIDs` and `resumeDataPendingTaskIDs` are empty, write the manifest,
   clear active maps/progress, and resume the caller continuation with the
   original error. Do not remove the scratch directory.

Classify `URLError` and `CancellationError` caused by sibling quiescing as
transport errors only when `preservingResumeData` is already true. Continue to
treat bad status, changed ETag, range mismatch, corrupt manifest, and file-size
errors as unsafe: cancel siblings, wait for callbacks, remove scratch, then
finish with the first unsafe error.

- [ ] **Step 5: Make explicit Cancel and cache removal destructive**

Replace `cancel(id:versionId:)` with routing for both engines:

```swift
public func cancel(id: Int, versionId: Int? = nil) {
    let key = cacheKey(videoId: id, versionId: versionId)
    let segmented = lock.withLock {
        segmentedAttempts[key].map { attempt in
            attempt.explicitlyCancelled = true
            return (
                attempt,
                attempt.taskIDs.compactMap { tasksByIdentifier[$0] }
            )
        }
    }
    if let (attempt, tasks) = segmented {
        finishSegmentedAttempt(
            attempt,
            result: .failure(CancellationError())
        )
        segmentedStore.remove(cacheKey: key)
        tasks.forEach { $0.cancel() }
    }

    let legacyTask = lock.withLock { tasksByKey[key] }
    legacyTask?.cancel()
}
```

Use the `tasksByIdentifier` map introduced in Task 2. Continue to populate it
when starting every segmented task and clear it in every completion path. This
avoids a blocking `URLSession.getAllTasks` call inside the lock.

On explicit cancellation, finishing the attempt immediately clears its
in-flight state and throws cancellation to the awaiting caller, allowing an
immediate retry. Resulting callbacks fail the attempt-identifier lookup, ignore
resume data, and remove no new-attempt state. Remove the old scratch directory
before cancelling tasks so the retry starts with a new probe.

Extend `removeAllCached(id:)`:

```swift
for manifest in segmentedStore.manifests() where manifest.videoId == id {
    segmentedStore.remove(cacheKey: manifest.cacheKey)
}
```

- [ ] **Step 6: Keep legacy resume tests green**

Retain the current legacy delegate maps and current tests:

- `resumeInterruptedRestartsPendingResumeFiles`
- `resumeInterruptedDropsStaleResumeWhenAlreadyCached`
- `resumeInterruptedSkipsLiveInFlightTask`
- `cancelThenImmediateSameKeyRetryCompletesIndependently`

Update only their call sites for the new optional bearer-token parameter.
Root-level `.resume` data must never be decoded as a segmented manifest.

- [ ] **Step 7: Run all cache/resume tests**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test --filter SegmentedDownloadTests
rtk test swift test --filter CacheManagerTests
rtk test swift test
```

Expected: fresh multiplexing, manifest resume, explicit cancellation, immediate
retry isolation, and legacy resume tests all pass.

- [ ] **Step 8: Commit durable resume support**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
rtk git add ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
rtk git add ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift
rtk git commit -m "feat(ios): resume multiplexed download segments"
```

### Task 4: Persist the setting and wire every production download

**Files:**

- Create: `ios/PatataTube/Sources/DownloadStreamSettings.swift`
- Create: `ios/PatataTube/Tests/DownloadStreamSettingsTests.swift`
- Create: `ios/PatataTube/Tests/SettingsViewTests.swift`
- Modify: `ios/PatataTube/Sources/AppModel.swift`
- Modify: `ios/PatataTube/Sources/SettingsView.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift`
- Regenerate: `ios/PatataTube/PatataTube.xcodeproj/project.pbxproj`

**Interfaces:**

- Produces:
  `DownloadStreamSettings(defaults:)`, `.load()`, `.save(_:)`,
  `.defaultCount == 2`, and `.allowedCounts == 1...4`.
- Produces: `AppModel.downloadStreamCount`.
- Changes `AppModel` initialization to accept test-safe injected credentials,
  cache, and download settings while preserving `AppModel()`.
- Passes the snapped model value from `VideoGridView` and `SettingsView`.
- Passes the current bearer token to foreground resume.

- [ ] **Step 1: Write failing setting-policy tests**

Create `DownloadStreamSettingsTests.swift`:

```swift
import Foundation
import Testing
import PatataTubeKit
@testable import PatataTube

@Suite("Download stream settings", .serialized)
@MainActor
struct DownloadStreamSettingsTests {
    private func defaults() throws -> UserDefaults {
        let name = "DownloadStreamSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToTwoAndClampsStoredValues() throws {
        let defaults = try defaults()
        let settings = DownloadStreamSettings(defaults: defaults)
        #expect(settings.load() == 2)

        defaults.set(-10, forKey: DownloadStreamSettings.key)
        #expect(settings.load() == 1)

        defaults.set(99, forKey: DownloadStreamSettings.key)
        #expect(settings.load() == 4)
    }

    @Test func appModelSavesTheSelectedCount() throws {
        let defaults = try defaults()
        let settings = DownloadStreamSettings(defaults: defaults)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("model-cache-\(UUID().uuidString)")
            ),
            downloadSettings: settings
        )

        model.downloadStreamCount = 3
        model.saveSettings()

        #expect(settings.load() == 3)
    }
}
```

- [ ] **Step 2: Run the focused test and verify compile failure**

Run from `ios/PatataTube` after generating the project:

```bash
rtk xcodegen generate
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadStreamSettingsTests
```

Expected: compilation fails because `DownloadStreamSettings`,
`downloadStreamCount`, and the injectable `AppModel` initializer do not exist.

- [ ] **Step 3: Implement the setting policy and AppModel ownership**

Create `DownloadStreamSettings.swift`:

```swift
import Foundation

struct DownloadStreamSettings {
    static let key = "downloadStreamCount"
    static let defaultCount = 2
    static let allowedCounts = 1...4

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Int {
        guard defaults.object(forKey: Self.key) != nil else {
            return Self.defaultCount
        }
        return min(max(defaults.integer(forKey: Self.key), Self.allowedCounts.lowerBound),
                   Self.allowedCounts.upperBound)
    }

    func save(_ count: Int) {
        let clamped = min(max(count, Self.allowedCounts.lowerBound),
                          Self.allowedCounts.upperBound)
        defaults.set(clamped, forKey: Self.key)
    }
}
```

Change `AppModel` to store the policy, publish its loaded value, and accept
test-safe dependencies:

```swift
private let downloadSettings: DownloadStreamSettings
@Published var downloadStreamCount: Int

init(
    credentials: CredentialStore = KeychainCredentialStore(),
    cache: CacheManager = CacheManager(),
    downloadSettings: DownloadStreamSettings = DownloadStreamSettings()
) {
    let api = APIClient(store: credentials)
    self.credentials = credentials
    self.cache = cache
    self.api = api
    self.store = VideoStore(api: api, cache: VideoListCache())
    self.downloadSettings = downloadSettings
    self.downloadStreamCount = downloadSettings.load()
    self.baseURLText = credentials.baseURL?.absoluteString ?? ""
    self.tokenText = credentials.token ?? ""
}
```

Add to `saveSettings()`:

```swift
downloadStreamCount = min(
    max(downloadStreamCount, DownloadStreamSettings.allowedCounts.lowerBound),
    DownloadStreamSettings.allowedCounts.upperBound
)
downloadSettings.save(downloadStreamCount)
```

- [ ] **Step 4: Add the Downloads section and UI test**

In `SettingsView`, insert between Server and Cache-all sections:

```swift
Section("Downloads") {
    Stepper(
        value: $model.downloadStreamCount,
        in: DownloadStreamSettings.allowedCounts
    ) {
        LabeledContent(
            "Streams per video",
            value: "\(model.downloadStreamCount)"
        )
    }
}
```

Create `SettingsViewTests.swift`:

```swift
import Foundation
import Testing
import ViewInspector
import PatataTubeKit
@testable import PatataTube

@Suite("Settings view", .serialized)
@MainActor
struct SettingsViewTests {
    @Test func showsTheSelectedStreamsPerVideo() throws {
        let defaults = try #require(UserDefaults(
            suiteName: "SettingsViewTests-\(UUID().uuidString)"
        ))
        defaults.set(3, forKey: DownloadStreamSettings.key)
        let model = AppModel(
            credentials: InMemoryCredentialStore(),
            cache: CacheManager(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("settings-cache-\(UUID().uuidString)")
            ),
            downloadSettings: DownloadStreamSettings(defaults: defaults)
        )
        let sut = SettingsView().environmentObject(model)

        let content = try sut.inspect().find(text: "Streams per video")
        #expect(try content.string() == "Streams per video")
        #expect(try sut.inspect().find(text: "3").string() == "3")
        #expect((try? sut.inspect().find(ViewType.Stepper.self)) != nil)
    }
}
```

- [ ] **Step 5: Pass the snapped count from both download call sites**

In `VideoGridView.download(_:)`, extend the existing call:

```swift
try await model.cache.download(
    id: target.id,
    versionId: target.chosenVersionId,
    from: url,
    preview: preview,
    showPosterKey: posterKey,
    showPoster: poster,
    bearerToken: model.credentials.token,
    streamCount: model.downloadStreamCount
)
```

In the Settings **Cache all videos** loop, extend the call the same way:

```swift
try? await model.cache.download(
    id: video.id,
    versionId: video.chosenVersionId,
    from: url,
    preview: preview,
    bearerToken: model.credentials.token,
    streamCount: model.downloadStreamCount
)
```

The `Int` parameter is copied when each async call begins. Do not read settings
from inside `CacheManager`; a resumed manifest continues to own its stored
count.

- [ ] **Step 6: Pass credentials into automatic resume**

In `PatataTubeApp`, replace:

```swift
model.cache.resumeInterrupted()
```

with:

```swift
model.cache.resumeInterrupted(bearerToken: model.credentials.token)
```

- [ ] **Step 7: Regenerate the project and run app tests**

Run from `ios/PatataTube`:

```bash
rtk xcodegen generate
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadStreamSettingsTests -only-testing:PatataTubeTests/SettingsViewTests
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: focused setting tests and the full PatataTube app test target pass.

- [ ] **Step 8: Commit settings and production wiring**

```bash
rtk git add ios/PatataTube/Sources/DownloadStreamSettings.swift
rtk git add ios/PatataTube/Sources/AppModel.swift
rtk git add ios/PatataTube/Sources/SettingsView.swift
rtk git add ios/PatataTube/Sources/VideoGridView.swift
rtk git add ios/PatataTube/Sources/PatataTubeApp.swift
rtk git add ios/PatataTube/Tests/DownloadStreamSettingsTests.swift
rtk git add ios/PatataTube/Tests/SettingsViewTests.swift
rtk git add ios/PatataTube/PatataTube.xcodeproj/project.pbxproj
rtk git commit -m "feat(ios): configure streams per video"
```

### Task 5: Lock down the server contract and update manual acceptance

**Files:**

- Modify: `tests/test_api.py`
- Modify: `ios/README.md`

**Interfaces:**

- Verifies the existing `/videos/{id}/stream` endpoint can supply four exact,
  independently recombinable ranges with one strong ETag.
- Documents the new setting, multiplexing, resume, relaunch, and cancellation
  checks.
- Does not change `router.py`.

- [ ] **Step 1: Add the explicit four-range server contract test**

Place this test beside the existing byte-range tests in `tests/test_api.py`:

```python
def test_stream_multiplex_ranges_recombine_to_original(client):
    import db

    payload = bytes(range(23))
    fake_video = Path("videos") / "1.mp4"
    fake_video.parent.mkdir(exist_ok=True)
    fake_video.write_bytes(payload)
    ranges = [(0, 4), (5, 10), (11, 16), (17, 22)]

    try:
        vid_id = db.add_video("https://twitter.com/x/status/1")
        db.update_video(vid_id, status="done", filename="1.mp4")

        responses = [
            client.get(
                f"/videos/{vid_id}/stream",
                headers={**AUTH, "Range": f"bytes={start}-{end}"},
            )
            for start, end in ranges
        ]

        etags = {response.headers["etag"] for response in responses}
        assert len(etags) == 1
        assert not next(iter(etags)).startswith("W/")
        assert b"".join(response.content for response in responses) == payload

        for response, (start, end) in zip(responses, ranges):
            assert response.status_code == 206
            assert response.headers["accept-ranges"] == "bytes"
            assert response.headers["content-range"] == f"bytes {start}-{end}/23"
            assert response.headers["content-length"] == str(end - start + 1)
    finally:
        fake_video.unlink(missing_ok=True)
```

- [ ] **Step 2: Run the focused backend tests**

Run from the repository root:

```bash
rtk pytest tests/test_api.py::test_stream_multiplex_ranges_recombine_to_original
rtk pytest tests/test_api.py -k 'stream and (range or concurrent)'
```

Expected: the new recombination contract and existing Range/If-Range/semaphore
tests pass without a production backend change.

- [ ] **Step 3: Update the iOS feature list and manual checklist**

Under **Offline / caching**, add:

```markdown
- Configurable 1–4 simultaneous byte-range streams per video (default 2)
```

Replace the single old resume checklist line with:

```markdown
- [ ] Set Streams per video to 4, download a large video, and confirm the
      server receives four disjoint byte ranges while the existing circular
      progress indicator advances to one cached MP4.
- [ ] Play the completed MP4 with network access disabled; verify playback and
      seeking across all former segment boundaries.
- [ ] Interrupt a four-stream download with Airplane Mode, restore the network,
      and verify completed segments are not requested again.
- [ ] Interrupt a download, terminate and relaunch the app, and verify the
      foreground resume completes using the original stream count.
- [ ] Change Streams per video while a download is interrupted; verify that
      download keeps its original ranges and the next new download uses the new
      count.
- [ ] Cancel a multiplexed download and immediately retry; verify progress
      starts at zero and no stale callback resets or corrupts the new attempt.
- [ ] Upgrade over an existing single-task `.resume` file and verify it
      completes as a legacy one-stream transfer.
```

Do not alter the existing shared download-button visual checks.

- [ ] **Step 4: Run the complete backend suite**

Run from the repository root:

```bash
rtk pytest tests/
```

Expected: all backend tests pass.

- [ ] **Step 5: Commit the server contract and acceptance docs**

`docs/` is ignored for new files, but `ios/README.md` and `tests/test_api.py`
are tracked normally:

```bash
rtk git add tests/test_api.py
rtk git add ios/README.md
rtk git commit -m "test: lock down multiplexed range downloads"
```

### Task 6: Final verification and scope audit

**Files:**

- Verify only; no planned source changes.

**Interfaces:**

- Verifies all approved spec requirements as one integrated feature.

- [ ] **Step 1: Run both Swift suites**

Run from `ios/PatataTubeKit`:

```bash
rtk test swift test
```

Run from `ios/PatataTube`:

```bash
rtk test xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: all PatataTubeKit and PatataTubeTests tests pass.

- [ ] **Step 2: Run the complete backend suite**

Run from the repository root:

```bash
rtk pytest tests/
```

Expected: all backend tests pass.

- [ ] **Step 3: Audit the exact HTTP and UI contracts**

Run from the repository root:

```bash
rtk rg -n 'downloadStreamCount|Streams per video|streamCount:' ios/PatataTube
rtk rg -n 'Range|If-Range|Content-Range|ETag' ios/PatataTubeKit/Sources/PatataTubeKit
rtk rg -n 'fallback|DownloadButton' ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
```

Expected:

- the setting key and both production download calls are present;
- fresh segment requests set `Range` and `If-Range`;
- probe and segment validation require `206` and a strong matching ETag;
- no full-response fallback exists; and
- `DownloadButton.swift` has no feature diff.

- [ ] **Step 4: Audit repository scope and commit history**

```bash
rtk git diff --check
rtk git status --short
rtk git log -7 --oneline
```

Expected: no whitespace errors or uncommitted implementation changes. The five
implementation commits appear above design commit `8239091`, and there is no
production `router.py` or `DownloadButton.swift` change.

- [ ] **Step 5: Perform the manual interruption checks before release**

Follow the seven new multiplexing checklist items in `ios/README.md` on a real
server and physical iPhone/iPad. In particular, inspect server access logs for
disjoint ranges and verify relaunch resume, since opaque URLSession resume data
cannot be faithfully generated by `URLProtocol`.

Expected: all seven items pass before invoking the repository's `deploy-ios`
skill for a release.
