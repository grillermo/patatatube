# Proxy Download Transfer Rates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure upstream network bytes and pre-existing stream-cache bytes at the iOS loopback proxy, then show independent live `Net` and `Cache` rates for HLS and MP4 offline downloads.

**Architecture:** `StreamProxy` gets dedicated offline-download routes backed by a shared `DownloadTransferMeter`. A bounded streaming bridge carries upstream and cached chunks without buffering whole MP4 ranges; proxy handlers assign every delivered chunk to exactly one source. `CacheManager` keeps ownership of progress, cancellation, and history, but overlays proxy meter snapshots onto `DownloadActivity`.

**Tech Stack:** Swift 6, iOS 17+, macOS 14+, SwiftPM, Foundation `URLSession`, FlyingFox/FlyingSocks, XCTest and swift-testing, SwiftUI, ViewInspector, XcodeGen.

## Global Constraints

- Prefix every shell command and every segment of a command chain with `rtk`.
- No backend or Caddy changes.
- Network rate counts upstream HTTP response-body bytes only; protocol overhead is excluded.
- Cache rate counts only bytes that existed in `SegmentCache` or `RangeStore` before the current proxy request.
- A newly fetched byte written to cache is network-only for that request.
- Playback routes never contribute to offline-download meters.
- Network and cache rates use independent trailing 2.5-second windows and return `nil` after 2.5 seconds without channel traffic.
- HLS's 10,000 units remain percentage bookkeeping only and never feed a speed field.
- Direct fallback remains functional but exposes both rates as unavailable.
- MP4 manifests persist stable upstream URLs; ephemeral proxy URLs exist only on live attempts.
- Existing cancellation, retry, cache-eviction, completion-history, and download-concurrency behavior remains intact.
- All behavior changes follow red-green-refactor: run each focused test and observe the expected failure before production edits.

## File map

| File | Responsibility |
|---|---|
| `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadTransferMeter.swift` | Thread-safe per-download generations, source totals, rolling rates, and stale-attempt fencing. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/ProxyStreamingBody.swift` | Bounded chunk channel, URLSession data-delegate bridge, and FlyingSocks body adapter. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxyDownloadHandler.swift` | Dedicated HLS and MP4 download handlers; exclusive network/cache source accounting. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift` | Route registration, download URL builders, and composition of the download handler. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/RangeStore.swift` | Chunk-sized reads/writes used by the streaming MP4 download handler. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift` | Public network/cache rate fields and progress-only accumulator. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` | Shared meter injection, proxy-aware MP4 source selection, activity overlay, lifecycle, and relaunch-safe request URLs. |
| `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift` | Proxy-aware HLS URL selection and disabling direct cache reuse in proxy mode. |
| `ios/PatataTube/Sources/AppModel.swift` | Construct and share one meter; expose current proxy download URLs. |
| `ios/PatataTube/Sources/VideoGridView.swift` | Pass stable upstream and current proxy URLs into explicit downloads. |
| `ios/PatataTube/Sources/PatataTubeApp.swift` | Resolve the current MP4 proxy URL when resuming persisted manifests. |
| `ios/PatataTube/Sources/DownloadsView.swift` | Render `Net … · Cache …` and accessibility copy. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadTransferMeterTests.swift` | Deterministic meter rate, decay, isolation, and generation tests. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/ProxyStreamingBodyTests.swift` | Ordered bounded streaming, backpressure, failure, and cancellation tests. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift` | Cold/warm/mixed HLS and MP4 route integration, exact ranges, and playback exclusion. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift` | Progress-only accumulator and transfer-rate overlay value tests. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift` | Proxy-mode HLS cache bypass, synthetic-unit isolation, and meter lifecycle. |
| `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift` | Proxy-mode MP4 seed bypass, stable manifests, live request URLs, relaunch, cancellation, and activity snapshots. |
| `ios/PatataTube/Tests/DownloadsViewTests.swift` | Dual-rate formatting, unavailable values, row layout, and accessibility. |

---

### Task 1: Deterministic dual-channel transfer meter

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadTransferMeter.swift`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadTransferMeterTests.swift`

**Interfaces:**
- Consumes: existing video/version cache-key strings such as `"7:2"`.
- Produces:
  - `public enum DownloadTransferSource: Sendable { case network, cache }`
  - `public struct DownloadTransferGeneration: Hashable, Sendable`
  - `public struct DownloadTransferSnapshot: Equatable, Sendable`
  - `public final class DownloadTransferMeter: @unchecked Sendable`
  - `begin(key:now:) -> DownloadTransferGeneration`
  - `generation(for:) -> DownloadTransferGeneration?`
  - `record(key:generation:source:bytes:now:)`
  - `snapshot(key:now:) -> DownloadTransferSnapshot?`
  - `end(key:generation:)`

- [ ] **Step 1: Write the failing meter tests**

```swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download transfer meter")
struct DownloadTransferMeterTests {
    @Test func channelsHaveIndependentRatesAndTotals() {
        let meter = DownloadTransferMeter(window: 2.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        let generation = meter.begin(key: "7:2", now: t0)

        meter.record(
            key: "7:2", generation: generation, source: .network,
            bytes: 2_000, now: t0.addingTimeInterval(1)
        )
        meter.record(
            key: "7:2", generation: generation, source: .cache,
            bytes: 6_000, now: t0.addingTimeInterval(2)
        )

        let snapshot = meter.snapshot(
            key: "7:2", now: t0.addingTimeInterval(2)
        )
        #expect(snapshot?.networkByteCount == 2_000)
        #expect(snapshot?.cacheByteCount == 6_000)
        #expect(snapshot?.networkBytesPerSecond == 1_000)
        #expect(snapshot?.cacheBytesPerSecond == 3_000)
    }

    @Test func inactiveChannelDecaysAfterWindow() {
        let meter = DownloadTransferMeter(window: 2.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 10)
        let generation = meter.begin(key: "8", now: t0)
        meter.record(
            key: "8", generation: generation, source: .network,
            bytes: 5_000, now: t0.addingTimeInterval(1)
        )

        #expect(
            meter.snapshot(key: "8", now: t0.addingTimeInterval(3.6))?
                .networkBytesPerSecond == nil
        )
    }

    @Test func oldGenerationCannotWriteIntoReplacement() {
        let meter = DownloadTransferMeter(window: 2.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 10)
        let old = meter.begin(key: "9", now: t0)
        meter.end(key: "9", generation: old)
        let replacement = meter.begin(key: "9", now: t0.addingTimeInterval(1))

        meter.record(
            key: "9", generation: old, source: .network,
            bytes: 99_000, now: t0.addingTimeInterval(2)
        )
        meter.record(
            key: "9", generation: replacement, source: .cache,
            bytes: 1_000, now: t0.addingTimeInterval(2)
        )

        let snapshot = meter.snapshot(
            key: "9", now: t0.addingTimeInterval(2)
        )
        #expect(snapshot?.networkByteCount == 0)
        #expect(snapshot?.cacheByteCount == 1_000)
    }
}
```

- [ ] **Step 2: Run the tests and verify the expected compile failure**

Run from `ios/PatataTubeKit`:

```bash
rtk swift test --filter DownloadTransferMeterTests
```

Expected: FAIL because `DownloadTransferMeter` and its value types do not exist.

- [ ] **Step 3: Implement the meter**

Use event byte counts, not cumulative samples. Prune events at or before
`now - window`; rate is the bytes remaining in the window divided by
`min(window, now - sessionStart)`.

```swift
import Foundation

public enum DownloadTransferSource: Sendable {
    case network
    case cache
}

public struct DownloadTransferGeneration: Hashable, Sendable {
    fileprivate let value: UUID
}

public struct DownloadTransferSnapshot: Equatable, Sendable {
    public let networkByteCount: Int64
    public let cacheByteCount: Int64
    public let networkBytesPerSecond: Double?
    public let cacheBytesPerSecond: Double?
}

public final class DownloadTransferMeter: @unchecked Sendable {
    private struct Event {
        let date: Date
        let bytes: Int64
    }

    private struct Entry {
        let generation: DownloadTransferGeneration
        let startedAt: Date
        var networkTotal: Int64 = 0
        var cacheTotal: Int64 = 0
        var networkEvents: [Event] = []
        var cacheEvents: [Event] = []
    }

    private let lock = NSLock()
    private let window: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(window: TimeInterval = 2.5) {
        precondition(window > 0)
        self.window = window
    }

    @discardableResult
    public func begin(
        key: String,
        now: Date = Date()
    ) -> DownloadTransferGeneration {
        let generation = DownloadTransferGeneration(value: UUID())
        lock.withLock {
            entries[key] = Entry(generation: generation, startedAt: now)
        }
        return generation
    }

    public func generation(for key: String) -> DownloadTransferGeneration? {
        lock.withLock { entries[key]?.generation }
    }

    public func record(
        key: String,
        generation: DownloadTransferGeneration,
        source: DownloadTransferSource,
        bytes: Int,
        now: Date = Date()
    ) {
        guard bytes > 0 else { return }
        lock.withLock {
            guard var entry = entries[key],
                  entry.generation == generation
            else { return }
            let event = Event(date: now, bytes: Int64(bytes))
            switch source {
            case .network:
                entry.networkTotal += event.bytes
                entry.networkEvents.append(event)
            case .cache:
                entry.cacheTotal += event.bytes
                entry.cacheEvents.append(event)
            }
            prune(&entry, now: now)
            entries[key] = entry
        }
    }

    public func snapshot(
        key: String,
        now: Date = Date()
    ) -> DownloadTransferSnapshot? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            prune(&entry, now: now)
            entries[key] = entry
            let elapsed = min(window, max(0, now.timeIntervalSince(entry.startedAt)))
            return DownloadTransferSnapshot(
                networkByteCount: entry.networkTotal,
                cacheByteCount: entry.cacheTotal,
                networkBytesPerSecond: rate(entry.networkEvents, elapsed: elapsed),
                cacheBytesPerSecond: rate(entry.cacheEvents, elapsed: elapsed)
            )
        }
    }

    public func end(key: String, generation: DownloadTransferGeneration) {
        lock.withLock {
            guard entries[key]?.generation == generation else { return }
            entries[key] = nil
        }
    }

    private func prune(_ entry: inout Entry, now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        entry.networkEvents.removeAll { $0.date <= cutoff }
        entry.cacheEvents.removeAll { $0.date <= cutoff }
    }

    private func rate(_ events: [Event], elapsed: TimeInterval) -> Double? {
        guard elapsed > 0 else { return nil }
        let bytes = events.reduce(Int64(0)) { $0 + $1.bytes }
        return bytes > 0 ? Double(bytes) / elapsed : nil
    }
}
```

- [ ] **Step 4: Run the focused meter tests**

```bash
rtk swift test --filter DownloadTransferMeterTests
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadTransferMeter.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadTransferMeterTests.swift
rtk git commit -m "feat(ios): add dual-channel download transfer meter"
```

---

### Task 2: Bounded URLSession-to-FlyingFox streaming bridge

**Files:**
- Modify: `ios/PatataTubeKit/Package.swift`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/ProxyStreamingBody.swift`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ProxyStreamingBodyTests.swift`

**Interfaces:**
- Consumes: FlyingFox `HTTPBodySequence`, FlyingSocks
  `AsyncBufferedSequence`, `URLSessionConfiguration`.
- Produces:
  - `actor BoundedChunkChannel`
  - `struct URLSessionChunkResponse`
  - `final class URLSessionChunkLoader`
  - `struct ProxyBodySequence: AsyncBufferedSequence`
  - `HTTPBodySequence(proxyChunks:count:)`

- [ ] **Step 1: Add failing ordered-stream, error, and cancellation tests**

Use a `URLProtocol` that calls `didLoad` with three distinct chunks and records
`stopLoading`. The assertions must consume the body through
`HTTPBodySequence.bodyData`, not by calling channel internals.

```swift
import FlyingFox
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Proxy streaming body")
struct ProxyStreamingBodyTests {
    @Test func urlSessionChunksReachHTTPBodyInOrder() async throws {
        ChunkedURLProtocol.configure(chunks: [
            Data("one".utf8), Data("-two".utf8), Data("-three".utf8),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let loader = URLSessionChunkLoader(configuration: configuration)

        let upstream = try await loader.response(
            for: URLRequest(url: URL(string: "https://u.test/body")!)
        )
        let body = HTTPBodySequence(
            proxyChunks: upstream.chunks,
            count: Int(upstream.response.expectedContentLength)
        )

        #expect(try await body.reduce(into: Data()) { $0.append($1) }
            == Data("one-two-three".utf8))
    }

    @Test func upstreamFailureTerminatesBodyWithError() async throws {
        ChunkedURLProtocol.configure(
            chunks: [Data("partial".utf8)],
            terminalError: URLError(.networkConnectionLost)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let upstream = try await URLSessionChunkLoader(
            configuration: configuration
        ).response(for: URLRequest(url: URL(string: "https://u.test/fail")!))

        await #expect(throws: URLError.self) {
            _ = try await HTTPBodySequence(
                proxyChunks: upstream.chunks,
                count: nil
            ).reduce(into: Data()) { $0.append($1) }
        }
    }

    @Test func endingBodyConsumptionCancelsUpstreamTask() async throws {
        ChunkedURLProtocol.configure(chunks: [Data(repeating: 1, count: 64)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let upstream = try await URLSessionChunkLoader(
            configuration: configuration
        ).response(for: URLRequest(url: URL(string: "https://u.test/cancel")!))

        var iterator = HTTPBodySequence(
            proxyChunks: upstream.chunks,
            count: nil
        ).makeAsyncIterator()
        _ = try await iterator.next()
        upstream.cancel()

        #expect(await ChunkedURLProtocol.waitForStop())
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
rtk swift test --filter ProxyStreamingBodyTests
```

Expected: FAIL because the streaming bridge types and initializer do not exist.

- [ ] **Step 3: Add FlyingSocks as a direct target dependency**

Change the package target dependency to:

```swift
.target(
    name: "PatataTubeKit",
    dependencies: [
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
    ]
)
```

- [ ] **Step 4: Implement a one-chunk bounded channel**

The channel must never drop data. A second writer suspends until the reader
removes the buffered chunk. `finish(throwing:)` resumes both readers and
writers, and `next()` throws the stored terminal error only after buffered data
is drained.

```swift
actor BoundedChunkChannel {
    private var buffered: Data?
    private var reader: CheckedContinuation<Data?, Error>?
    private var writers: [(Data, CheckedContinuation<Void, Error>)] = []
    private var terminal: Result<Void, Error>?

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if let terminal { return try terminal.get() }
        if let reader {
            self.reader = nil
            reader.resume(returning: data)
            return
        }
        if buffered == nil {
            buffered = data
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            writers.append((data, continuation))
        }
    }

    func next() async throws -> Data? {
        if let buffered {
            self.buffered = nil
            promoteWriter()
            return buffered
        }
        if let terminal {
            try terminal.get()
            return nil
        }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func finish(throwing error: Error? = nil) {
        guard terminal == nil else { return }
        terminal = error.map(Result.failure) ?? .success(())
        if buffered == nil, let reader {
            self.reader = nil
            if let error { reader.resume(throwing: error) }
            else { reader.resume(returning: nil) }
        }
        let pending = writers
        writers = []
        for (_, writer) in pending {
            if let error { writer.resume(throwing: error) }
            else { writer.resume(returning: ()) }
        }
    }

    private func promoteWriter() {
        guard buffered == nil, !writers.isEmpty else { return }
        let (data, continuation) = writers.removeFirst()
        buffered = data
        continuation.resume(returning: ())
    }
}
```

- [ ] **Step 5: Implement `URLSessionChunkLoader`**

Use one delegate-owned session. Store task state by identifier before resuming.
In `didReceive data`, suspend the data task, await `channel.send(data)`, then
resume. This gives the one-chunk channel backpressure and preserves callback
order.

```swift
struct URLSessionChunkResponse: Sendable {
    let response: HTTPURLResponse
    let chunks: BoundedChunkChannel
    let cancel: @Sendable () -> Void
}

final class URLSessionChunkLoader:
    NSObject, URLSessionDataDelegate, @unchecked Sendable
{
    private final class State: @unchecked Sendable {
        let channel = BoundedChunkChannel()
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        var response: CheckedContinuation<URLSessionChunkResponse, Error>?
        var didPublishResponse = false

        func install(_ task: URLSessionDataTask) {
            let shouldCancel = lock.withLock {
                self.task = task
                return cancelled
            }
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return task
            }
            task?.cancel()
        }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    func response(for request: URLRequest) async throws -> URLSessionChunkResponse {
        let state = State()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                state.response = continuation
                lock.withLock { states[task.taskIdentifier] = state }
                state.install(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let state = lock.withLock({ states[dataTask.taskIdentifier] })
        else {
            completionHandler(.cancel)
            return
        }
        state.didPublishResponse = true
        state.response?.resume(returning: URLSessionChunkResponse(
            response: http,
            chunks: state.channel,
            cancel: { dataTask.cancel() }
        ))
        state.response = nil
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let state = lock.withLock({
            states[dataTask.taskIdentifier]
        }) else { return }
        dataTask.suspend()
        Task {
            do {
                try await state.channel.send(data)
                dataTask.resume()
            } catch {
                dataTask.cancel()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = lock.withLock({
            states.removeValue(forKey: task.taskIdentifier)
        }) else { return }
        if !state.didPublishResponse {
            state.response?.resume(
                throwing: error ?? URLError(.badServerResponse)
            )
        }
        Task { await state.channel.finish(throwing: error) }
    }
}
```

- [ ] **Step 6: Implement the FlyingSocks adapter**

`ProxyBodySequence.Iterator` retains a remainder when FlyingFox requests less
than the upstream chunk. Its `next()` delegates to `nextBuffer(suggested: 1)`.

```swift
import FlyingFox
import FlyingSocks

struct ProxyBodySequence: AsyncBufferedSequence {
    typealias Element = UInt8
    let channel: BoundedChunkChannel

    func makeAsyncIterator() -> Iterator {
        Iterator(channel: channel)
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Buffer = Data
        let channel: BoundedChunkChannel
        var remainder = Data()

        mutating func next() async throws -> UInt8? {
            guard let data = try await nextBuffer(suggested: 1) else {
                return nil
            }
            return data.first
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            if remainder.isEmpty {
                guard let chunk = try await channel.next() else { return nil }
                remainder = chunk
            }
            let length = min(max(count, 1), remainder.count)
            let result = Data(remainder.prefix(length))
            remainder.removeFirst(length)
            return result
        }
    }
}

extension HTTPBodySequence {
    init(
        proxyChunks: BoundedChunkChannel,
        count: Int?,
        suggestedBufferSize: Int = 64 * 1024
    ) {
        let bytes = ProxyBodySequence(channel: proxyChunks)
        if let count {
            self.init(
                from: bytes,
                count: count,
                suggestedBufferSize: suggestedBufferSize
            )
        } else {
            self.init(from: bytes, suggestedBufferSize: suggestedBufferSize)
        }
    }
}
```

- [ ] **Step 7: Run focused tests and the package build**

```bash
rtk swift test --filter ProxyStreamingBodyTests
rtk swift build
```

Expected: focused tests PASS; package build exits 0 under Swift 6 concurrency
checking.

- [ ] **Step 8: Commit**

```bash
rtk git add ios/PatataTubeKit/Package.swift ios/PatataTubeKit/Sources/PatataTubeKit/ProxyStreamingBody.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/ProxyStreamingBodyTests.swift
rtk git commit -m "feat(ios): add bounded proxy response streaming"
```

---

### Task 3: Dedicated metered HLS download route

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxyDownloadHandler.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift`

**Interfaces:**
- Consumes:
  - `DownloadTransferMeter.generation(for:)`
  - `URLSessionChunkLoader.response(for:)`
  - `SegmentCache.cachedData/store/dropOtherPackages`
- Produces:
  - `StreamProxy.downloadHLSURL(videoId:versionId:) -> URL?`
  - `StreamProxyDownloadHandler.handleHLS(_:) async -> HTTPResponse`
  - Dedicated route `GET /<secret>/download/hls/:id/:v/*`

- [ ] **Step 1: Write failing cold, warm, mixed, and playback-exclusion tests**

Add `private var meter: DownloadTransferMeter!` to `StreamProxyTests`, construct
it in `setUp`, and pass it as `transferMeter:` to `StreamProxy`. Use unique
video ids so cache state cannot leak between assertions.

```swift
func testDownloadHLSColdAssetRecordsNetworkOnly() async throws {
    let generation = meter.begin(key: "51", now: .now)
    defer { meter.end(key: "51", generation: generation) }
    let media = Data("#EXTM3U\n#EXTINF:6,\nsegment.m4s\n".utf8)
    let segment = Data(repeating: 7, count: 256 * 1024)
    MockURLProtocol.stub(path: "/videos/51/hls/video.m3u8", data: media)
    MockURLProtocol.stub(path: "/videos/51/hls/segment.m4s", data: segment)

    let base = try XCTUnwrap(
        proxy.downloadHLSURL(videoId: 51, versionId: nil)
    ).deletingLastPathComponent()
    _ = try await get(base.appendingPathComponent("video.m3u8"))
    let before = try XCTUnwrap(meter.snapshot(key: "51", now: .now))
    let (body, response) = try await get(
        base.appendingPathComponent("segment.m4s")
    )

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(body, segment)
    let after = try XCTUnwrap(meter.snapshot(key: "51", now: .now))
    XCTAssertEqual(
        after.networkByteCount - before.networkByteCount,
        Int64(segment.count)
    )
    XCTAssertEqual(after.cacheByteCount - before.cacheByteCount, 0)
}

func testDownloadHLSWarmAssetRecordsCacheOnly() async throws {
    let media = Data("#EXTM3U\n#EXTINF:6,\nsegment.m4s\n".utf8)
    let segment = Data(repeating: 8, count: 128 * 1024)
    MockURLProtocol.stub(path: "/videos/52/hls/video.m3u8", data: media)
    MockURLProtocol.stub(path: "/videos/52/hls/segment.m4s", data: segment)

    let playbackBase = try XCTUnwrap(
        proxy.hlsURL(videoId: 52, versionId: nil)
    ).deletingLastPathComponent()
    _ = try await get(playbackBase.appendingPathComponent("video.m3u8"))
    _ = try await get(playbackBase.appendingPathComponent("segment.m4s"))

    let generation = meter.begin(key: "52", now: .now)
    defer { meter.end(key: "52", generation: generation) }
    let downloadBase = try XCTUnwrap(
        proxy.downloadHLSURL(videoId: 52, versionId: nil)
    ).deletingLastPathComponent()
    _ = try await get(downloadBase.appendingPathComponent("video.m3u8"))
    let before = try XCTUnwrap(meter.snapshot(key: "52", now: .now))
    let upstreamBefore = MockURLProtocol.requestCount(
        path: "/videos/52/hls/segment.m4s"
    )
    let (received, _) = try await get(
        downloadBase.appendingPathComponent("segment.m4s")
    )
    let after = try XCTUnwrap(meter.snapshot(key: "52", now: .now))

    XCTAssertEqual(received, segment)
    XCTAssertEqual(
        MockURLProtocol.requestCount(path: "/videos/52/hls/segment.m4s"),
        upstreamBefore
    )
    XCTAssertEqual(after.networkByteCount - before.networkByteCount, 0)
    XCTAssertEqual(
        after.cacheByteCount - before.cacheByteCount,
        Int64(segment.count)
    )
}

func testDownloadHLSMixedPackageKeepsSourcesSeparate() async throws {
    let media = Data(
        "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.m4s\n".utf8
    )
    let initial = Data(repeating: 3, count: 64 * 1024)
    let segment = Data(repeating: 4, count: 96 * 1024)
    MockURLProtocol.stub(path: "/videos/53/hls/video.m3u8", data: media)
    MockURLProtocol.stub(path: "/videos/53/hls/init.mp4", data: initial)
    MockURLProtocol.stub(path: "/videos/53/hls/segment.m4s", data: segment)

    let playbackBase = try XCTUnwrap(
        proxy.hlsURL(videoId: 53, versionId: nil)
    ).deletingLastPathComponent()
    _ = try await get(playbackBase.appendingPathComponent("video.m3u8"))
    _ = try await get(playbackBase.appendingPathComponent("init.mp4"))

    let generation = meter.begin(key: "53", now: .now)
    defer { meter.end(key: "53", generation: generation) }
    let downloadBase = try XCTUnwrap(
        proxy.downloadHLSURL(videoId: 53, versionId: nil)
    ).deletingLastPathComponent()
    _ = try await get(downloadBase.appendingPathComponent("video.m3u8"))
    let before = try XCTUnwrap(meter.snapshot(key: "53", now: .now))
    _ = try await get(downloadBase.appendingPathComponent("init.mp4"))
    _ = try await get(downloadBase.appendingPathComponent("segment.m4s"))
    let after = try XCTUnwrap(meter.snapshot(key: "53", now: .now))

    XCTAssertEqual(
        after.cacheByteCount - before.cacheByteCount,
        Int64(initial.count)
    )
    XCTAssertEqual(
        after.networkByteCount - before.networkByteCount,
        Int64(segment.count)
    )
}

func testPlaybackHLSRouteDoesNotRecordActiveDownloadMeter() async throws {
    let media = Data("#EXTM3U\n#EXTINF:6,\nsegment.m4s\n".utf8)
    MockURLProtocol.stub(path: "/videos/54/hls/video.m3u8", data: media)
    MockURLProtocol.stub(
        path: "/videos/54/hls/segment.m4s",
        data: Data(repeating: 5, count: 4096)
    )
    let generation = meter.begin(key: "54", now: .now)
    defer { meter.end(key: "54", generation: generation) }
    let base = try XCTUnwrap(
        proxy.hlsURL(videoId: 54, versionId: nil)
    ).deletingLastPathComponent()

    _ = try await get(base.appendingPathComponent("video.m3u8"))
    _ = try await get(base.appendingPathComponent("segment.m4s"))

    let snapshot = try XCTUnwrap(meter.snapshot(key: "54", now: .now))
    XCTAssertEqual(snapshot.networkByteCount, 0)
    XCTAssertEqual(snapshot.cacheByteCount, 0)
}
```

- [ ] **Step 2: Run HLS proxy tests and verify RED**

```bash
rtk swift test --filter StreamProxyTests/testDownloadHLS
```

Expected: FAIL because `downloadHLSURL` and the dedicated handler do not exist.

- [ ] **Step 3: Add the handler and route surface**

`StreamProxy` receives a shared meter, creates one `URLSessionChunkLoader` from
the injected session's configuration, and passes both to the handler:

```swift
public init(
    cache: StreamCache,
    credentials: CredentialStore,
    session: URLSession = .shared,
    offlineRoot: URL? = nil,
    transferMeter: DownloadTransferMeter? = nil
) {
    self.cache = cache
    self.credentials = credentials
    self.session = session
    self.offlineRoot = offlineRoot
    self.transferMeter = transferMeter
    self.downloadHandler = StreamProxyDownloadHandler(
        cache: cache,
        credentials: credentials,
        loader: URLSessionChunkLoader(configuration: session.configuration),
        meter: transferMeter
    )
}

public func downloadHLSURL(videoId: Int, versionId: Int?) -> URL? {
    localURL(
        kind: "download/hls",
        videoId: videoId,
        versionId: versionId,
        suffix: "/master.m3u8"
    )
}
```

Register:

```swift
await server.appendRoute(
    HTTPRoute("GET /\(secret)/download/hls/:id/:v/*")
) { [downloadHandler] request in
    await downloadHandler.handleHLS(request)
}
```

- [ ] **Step 4: Implement HLS identity, playlists, and media bodies**

The handler keeps its own video/version-to-package-hash map. Playlists may
buffer because they must be parsed before choosing a package. Record buffered
playlist bytes as network under the request's captured generation. Capture
`meter?.generation(for: key)` exactly once at handler entry and pass that value
through the response body; never look up a replacement generation mid-stream.

For a cached media asset, stream bounded `Data` slices through a channel:

```swift
private func cachedHLSResponse(
    data: Data,
    contentType: String,
    key: String,
    generation: DownloadTransferGeneration?
) -> HTTPResponse {
    let channel = BoundedChunkChannel()
    Task {
        do {
            for offset in stride(from: 0, to: data.count, by: 1_048_576) {
                let chunk = data[offset..<min(offset + 1_048_576, data.count)]
                if let generation {
                    meter?.record(
                        key: key, generation: generation, source: .cache,
                        bytes: chunk.count
                    )
                }
                try await channel.send(Data(chunk))
            }
            await channel.finish()
        } catch {
            await channel.finish(throwing: error)
        }
    }
    return HTTPResponse(
        statusCode: .ok,
        headers: [.contentType: contentType],
        body: HTTPBodySequence(proxyChunks: channel, count: data.count)
    )
}
```

For an upstream media asset:

1. Await headers from `URLSessionChunkLoader`.
2. Reject non-2xx before constructing the local response.
3. Create a forwarding task that drains the loader channel.
4. Record every received chunk as network before forwarding.
5. Accumulate the asset data.
6. On clean EOF, finish the client channel and call the existing bounded
   `storeHLSAssetWithRecovery` equivalent on the handler.
7. On error, finish the client channel with the same error and do not cache a
   partial asset.

Do not use playback `SingleFlight` in this handler.

- [ ] **Step 5: Run HLS route and existing playback proxy tests**

```bash
rtk swift test --filter StreamProxyTests
```

Expected: all StreamProxy tests PASS, proving the new route did not change
playback behavior.

- [ ] **Step 6: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxyDownloadHandler.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift
rtk git commit -m "feat(ios): meter HLS downloads at stream proxy"
```

---

### Task 4: Exact-range mixed-source MP4 download route

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/RangeStore.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxyDownloadHandler.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift`

**Interfaces:**
- Consumes: `RangeStoreManifest`, `ByteRangeSet.missingRanges(in:)`,
  `URLSessionChunkLoader`, `DownloadTransferMeter`.
- Produces:
  - `StreamProxy.downloadMP4URL(videoId:versionId:) -> URL?`
  - Dedicated route `GET /<secret>/download/mp4/:id/:v`
  - `RangeStore.readChunk(key:range:maxCount:)`
  - Exact `206`, `Content-Range`, `Content-Length`, `Accept-Ranges`, and ETag.

- [ ] **Step 1: Write failing cold, warm, mixed, large-range, and playback tests**

Use a body larger than the playback window:

```swift
func testDownloadMP4RangeLargerThanPlaybackWindowIsNotTruncated() async throws {
    let body = Data(repeating: 6, count: 10 * 1024 * 1024)
    MockURLProtocol.stubRanged(path: "/videos/61/stream", fullBody: body, etag: "\"e1\"")
    let generation = meter.begin(key: "61", now: .now)
    defer { meter.end(key: "61", generation: generation) }

    let url = try XCTUnwrap(
        proxy.downloadMP4URL(videoId: 61, versionId: nil)
    )
    let requested = "bytes=0-\(body.count - 1)"
    let (received, response) = try await get(url, range: requested)

    XCTAssertEqual(response.statusCode, 206)
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"),
                   "bytes 0-\(body.count - 1)/\(body.count)")
    XCTAssertEqual(received, body)
    XCTAssertEqual(
        meter.snapshot(key: "61", now: .now)?.networkByteCount,
        Int64(body.count + 1)
    )
}

func testDownloadMP4MixedRangeCountsExistingBytesAsCacheOnly() async throws {
    let body = Data((0..<3072).map { UInt8($0 % 251) })
    MockURLProtocol.stubRanged(
        path: "/videos/62/stream", fullBody: body, etag: "\"e1\""
    )
    try await cache.ranges.prepare(
        key: "62", etag: "\"e1\"", totalByteCount: Int64(body.count)
    )
    try await cache.ranges.write(
        key: "62", at: 0, data: body.subdata(in: 0..<1024)
    )
    let generation = meter.begin(key: "62", now: .now)
    defer { meter.end(key: "62", generation: generation) }
    let url = try XCTUnwrap(
        proxy.downloadMP4URL(videoId: 62, versionId: nil)
    )

    let (received, response) = try await get(url, range: "bytes=0-3071")
    let snapshot = try XCTUnwrap(meter.snapshot(key: "62", now: .now))

    XCTAssertEqual(response.statusCode, 206)
    XCTAssertEqual(received, body)
    XCTAssertEqual(snapshot.cacheByteCount, 1024)
    XCTAssertEqual(snapshot.networkByteCount, 2048)
    XCTAssertEqual(
        snapshot.cacheByteCount + snapshot.networkByteCount,
        Int64(received.count)
    )
}

func testDownloadMP4FullyCachedRangeMakesNoUpstreamBodyRequest() async throws {
    let body = Data((0..<4096).map { UInt8($0 % 251) })
    try await cache.ranges.prepare(
        key: "63", etag: "\"e1\"", totalByteCount: Int64(body.count)
    )
    try await cache.ranges.write(key: "63", at: 0, data: body)
    let generation = meter.begin(key: "63", now: .now)
    defer { meter.end(key: "63", generation: generation) }
    let before = MockURLProtocol.requestCount(path: "/videos/63/stream")
    let url = try XCTUnwrap(
        proxy.downloadMP4URL(videoId: 63, versionId: nil)
    )

    let (received, _) = try await get(url, range: "bytes=0-4095")
    let snapshot = try XCTUnwrap(meter.snapshot(key: "63", now: .now))

    XCTAssertEqual(received, body)
    XCTAssertEqual(snapshot.cacheByteCount, 4096)
    XCTAssertEqual(snapshot.networkByteCount, 0)
    XCTAssertEqual(
        MockURLProtocol.requestCount(path: "/videos/63/stream"),
        before
    )
}

func testPlaybackMP4RouteDoesNotRecordActiveDownloadMeter() async throws {
    let body = Data(repeating: 9, count: 4096)
    MockURLProtocol.stubRanged(
        path: "/videos/64/stream", fullBody: body, etag: "\"e1\""
    )
    let generation = meter.begin(key: "64", now: .now)
    defer { meter.end(key: "64", generation: generation) }
    let url = try XCTUnwrap(proxy.mp4URL(videoId: 64, versionId: nil))

    _ = try await get(url, range: "bytes=0-4095")

    let snapshot = try XCTUnwrap(meter.snapshot(key: "64", now: .now))
    XCTAssertEqual(snapshot.networkByteCount, 0)
    XCTAssertEqual(snapshot.cacheByteCount, 0)
}

func testDownloadMP4CacheFailureFallsThroughAsNetworkOnly() async throws {
    let body = Data(repeating: 2, count: 4096)
    MockURLProtocol.stubRanged(
        path: "/videos/65/stream", fullBody: body, etag: "\"e1\""
    )
    let mp4Root = root.appendingPathComponent("mp4", isDirectory: true)
    try FileManager.default.removeItem(at: mp4Root)
    try Data().write(to: mp4Root)
    let generation = meter.begin(key: "65", now: .now)
    defer { meter.end(key: "65", generation: generation) }
    let url = try XCTUnwrap(
        proxy.downloadMP4URL(videoId: 65, versionId: nil)
    )

    let (received, _) = try await get(url, range: "bytes=0-4095")
    let snapshot = try XCTUnwrap(meter.snapshot(key: "65", now: .now))

    XCTAssertEqual(received, body)
    XCTAssertEqual(snapshot.cacheByteCount, 0)
    XCTAssertGreaterThanOrEqual(snapshot.networkByteCount, Int64(body.count))
}
```

- [ ] **Step 2: Run MP4 download-route tests and verify RED**

```bash
rtk swift test --filter StreamProxyTests/testDownloadMP4
```

Expected: FAIL because `downloadMP4URL` and exact-range download handling do not
exist.

- [ ] **Step 3: Add chunk-sized RangeStore reading**

The method verifies the requested span is committed, then returns at most
`maxCount` bytes starting at `range.start`:

```swift
func readChunk(
    key: String,
    range: DownloadByteRange,
    maxCount: Int
) throws -> Data? {
    guard maxCount > 0,
          let manifest = manifest(key: key),
          isValid(range, for: manifest),
          manifest.ranges.contains(range)
    else { return nil }
    let count = min(Int64(maxCount), range.length)
    let handle = try FileHandle(forReadingFrom: dataURL(key: key))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(range.start))
    guard let data = try handle.read(upToCount: Int(count)),
          data.count == Int(count)
    else {
        remove(key: key)
        return nil
    }
    return data
}
```

- [ ] **Step 4: Add the URL builder and route**

```swift
public func downloadMP4URL(videoId: Int, versionId: Int?) -> URL? {
    localURL(
        kind: "download/mp4",
        videoId: videoId,
        versionId: versionId,
        suffix: ""
    )
}
```

Register `GET /<secret>/download/mp4/:id/:v` beside the HLS download route.

- [ ] **Step 5: Implement the ordered mixed-source body**

The handler must:

1. Resolve the upstream `/videos/<id>/stream` URL.
2. Use an existing matching `RangeStoreManifest`, or perform the same
   `bytes=0-0` strong-ETag probe as the playback handler and prepare the store.
3. Parse the complete client `Range` without the playback 8 MiB cap.
4. Snapshot `manifest.ranges` before starting the body.
5. Capture `meter?.generation(for: key)` once for the response lifetime.
6. Partition the request into alternating cached spans and missing spans.
7. Return exact response headers immediately.
8. Stream every span sequentially through one output channel.

Represent the immutable source plan explicitly:

```swift
private enum MP4Span: Sendable {
    case cache(DownloadByteRange)
    case upstream(DownloadByteRange)
}
```

For `.cache`, call `readChunk` in 1 MiB pieces and record `.cache` immediately
before sending each chunk. If a committed read fails, replace the unread
remainder with one upstream span; do not count the failed read.

For `.upstream`:

- Request that exact hole with `If-Range: <manifest.etag>`.
- Require `206`, the same ETag, and an exact `Content-Range`.
- Record each received chunk as `.network`.
- Best-effort write each chunk at the advancing absolute offset with
  `expectedETag` and `expectedTotalByteCount`.
- Forward the same chunk without reading it back from cache.
- If ETag or range validation fails, remove the stale range entry and terminate
  the response so the existing downloader retries against a fresh probe.

The invariant checked at EOF is:

```swift
guard deliveredByteCount == requestedRange.length else {
    throw SegmentedDownloadError.lengthMismatch(
        expected: requestedRange.length,
        actual: deliveredByteCount
    )
}
```

- [ ] **Step 6: Run all StreamProxy tests**

```bash
rtk swift test --filter StreamProxyTests
```

Expected: PASS, including existing playback ETag and cache-fallback coverage.

- [ ] **Step 7: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/RangeStore.swift ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxy.swift ios/PatataTubeKit/Sources/PatataTubeKit/StreamProxyDownloadHandler.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift
rtk git commit -m "feat(ios): stream mixed-source MP4 download ranges"
```

---

### Task 5: Make DownloadActivity rates proxy-owned

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift`

**Interfaces:**
- Consumes: `DownloadTransferSnapshot`.
- Produces:
  - `DownloadActivity.cacheBytesPerSecond: Double?`
  - `DownloadActivity.applying(_:) -> DownloadActivity`
  - A progress-only `DownloadActivityAccumulator`.

- [ ] **Step 1: Replace accumulator-rate tests with failing activity overlay tests**

Keep completion-history tests unchanged. Replace the four old sampling tests
with:

```swift
@Test func accumulatorRecordsProgressWithoutInventingSpeed() {
    var accumulator = DownloadActivityAccumulator(
        videoID: 7,
        versionID: 2,
        totalByteCount: 10_000
    )
    accumulator.record(
        transferredByteCount: 5_000,
        progress: 0.5
    )

    #expect(accumulator.activity.progress == 0.5)
    #expect(accumulator.activity.transferredByteCount == 5_000)
    #expect(accumulator.activity.bytesPerSecond == nil)
    #expect(accumulator.activity.cacheBytesPerSecond == nil)
}

@Test func transferSnapshotPopulatesNetworkAndCacheRates() {
    let activity = DownloadActivity(
        videoID: 7, versionID: 2, progress: 0.5,
        transferredByteCount: 5_000, totalByteCount: 10_000,
        bytesPerSecond: nil, cacheBytesPerSecond: nil
    )
    let measured = activity.applying(DownloadTransferSnapshot(
        networkByteCount: 4_000,
        cacheByteCount: 1_000,
        networkBytesPerSecond: 2_000,
        cacheBytesPerSecond: 500
    ))

    #expect(measured.bytesPerSecond == 2_000)
    #expect(measured.cacheBytesPerSecond == 500)
    #expect(measured.progress == activity.progress)
}
```

- [ ] **Step 2: Run and verify RED**

```bash
rtk swift test --filter DownloadActivityTests
```

Expected: compile failure for `cacheBytesPerSecond` and `applying`.

- [ ] **Step 3: Add the cache rate and progress-only accumulator**

Add `cacheBytesPerSecond` to the public initializer with a default of `nil` so
unrelated callers compile. Implement `applying` by reconstructing the value
with the two snapshot rates and unchanged identity/progress/count fields.

Remove `averagingWindow`, samples, `establishResumeSamplingBaseline`, and
`averagedRate`. The accumulator initializer no longer takes `now`, and
`record` no longer takes `now`; every base activity rate is `nil`.

- [ ] **Step 4: Run activity tests**

```bash
rtk swift test --filter DownloadActivityTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/DownloadActivity.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/DownloadActivityTests.swift
rtk git commit -m "refactor(ios): make download activity rates proxy-owned"
```

---

### Task 6: Proxy-aware HLS CacheManager lifecycle

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: shared `DownloadTransferMeter`; proxy HLS master URL.
- Produces:
  - `CacheManager` initializers with optional
    `transferMeter: DownloadTransferMeter? = nil`
  - `downloadHLS(..., proxyMasterURL: URL? = nil, ...)`
  - meter begin/end coupled to external activity ownership.

- [ ] **Step 1: Write failing proxy-mode HLS tests**

Add this focused stub helper inside `CacheManagerHLSTests`:

```swift
private func stubProxyHLS(videoID: Int) {
    let prefix = "/download/hls/\(videoID)/0"
    MockURLProtocol.stub(
        path: "\(prefix)/master.m3u8",
        data: Data("#EXTM3U\nvideo.m3u8\n".utf8)
    )
    MockURLProtocol.stub(
        path: "\(prefix)/video.m3u8",
        data: Data(
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.m4s\n".utf8
        )
    )
    MockURLProtocol.stub(path: "\(prefix)/init.mp4", data: Data([1]))
    MockURLProtocol.stub(path: "\(prefix)/segment.m4s", data: Data([2]))
}

func testProxyManagedHLSDoesNotReuseSegmentCacheDirectly() async throws {
    let videoID = 15
    let mediaData = Data(
        "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\nsegment.m4s\n".utf8
    )
    let hash = SegmentCache.packageHash(forPlaylist: mediaData)
    try await streamCache.segments.store(
        videoId: videoID,
        hash: hash,
        asset: "init.mp4",
        data: Data([99])
    )
    stubProxyHLS(videoID: videoID)
    let proxy = URL(
        string: "http://127.0.0.1:43123/download/hls/\(videoID)/0/master.m3u8"
    )!

    try await cache.downloadHLS(
        id: videoID,
        masterURL: URL(
            string: "https://u.test/videos/\(videoID)/hls/master.m3u8"
        )!,
        proxyMasterURL: proxy,
        bearerToken: "tok"
    )

    XCTAssertEqual(
        MockURLProtocol.requestCount(
            path: "/download/hls/\(videoID)/0/init.mp4"
        ),
        1
    )
}

func testHLSProgressUnitsNeverBecomeTransferRates() async throws {
    let videoID = 16
    let meter = DownloadTransferMeter()
    let gate = HLSPromotionGate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let manager = CacheManager(
        root: root.appendingPathComponent("meter-videos"),
        configuration: configuration,
        fileManager: .default,
        streamCache: streamCache,
        transferMeter: meter,
        beforeExternalPromotion: { await gate.waitForRelease() }
    )
    stubProxyHLS(videoID: videoID)
    let proxy = URL(
        string: "http://127.0.0.1:43123/download/hls/\(videoID)/0/master.m3u8"
    )!
    let download = Task {
        try await manager.downloadHLS(
            id: videoID,
            masterURL: URL(
                string: "https://u.test/videos/\(videoID)/hls/master.m3u8"
            )!,
            proxyMasterURL: proxy,
            bearerToken: "tok"
        )
    }

    await gate.waitUntilEntered()
    let activity = try XCTUnwrap(manager.activeDownloads().first)
    XCTAssertGreaterThan(activity.progress, 0)
    XCTAssertNil(activity.bytesPerSecond)
    XCTAssertNil(activity.cacheBytesPerSecond)
    await gate.release()
    try await download.value
}

func testProxyHLSActivityUsesMeterSnapshotAndEndsOnCancel() async throws {
    let videoID = 17
    let meter = DownloadTransferMeter()
    let gate = HLSPromotionGate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let manager = CacheManager(
        root: root.appendingPathComponent("cancel-meter-videos"),
        configuration: configuration,
        fileManager: .default,
        streamCache: streamCache,
        transferMeter: meter,
        beforeExternalPromotion: { await gate.waitForRelease() }
    )
    stubProxyHLS(videoID: videoID)
    let proxy = URL(
        string: "http://127.0.0.1:43123/download/hls/\(videoID)/0/master.m3u8"
    )!
    let download = Task {
        try await manager.downloadHLS(
            id: videoID,
            masterURL: URL(
                string: "https://u.test/videos/\(videoID)/hls/master.m3u8"
            )!,
            proxyMasterURL: proxy,
            bearerToken: "tok"
        )
    }

    await gate.waitUntilEntered()
    let generation = try XCTUnwrap(meter.generation(for: "\(videoID)"))
    let sampleTime = Date()
    meter.record(
        key: "\(videoID)", generation: generation, source: .network,
        bytes: 2 * 1024 * 1024, now: sampleTime
    )
    meter.record(
        key: "\(videoID)", generation: generation, source: .cache,
        bytes: 1024 * 1024, now: sampleTime
    )
    let activity = try XCTUnwrap(manager.activeDownloads().first)
    XCTAssertGreaterThan(activity.bytesPerSecond ?? 0, 0)
    XCTAssertGreaterThan(activity.cacheBytesPerSecond ?? 0, 0)

    manager.cancel(id: videoID)
    await gate.release()
    _ = try? await download.value
    XCTAssertNil(meter.snapshot(key: "\(videoID)", now: Date()))
}

func testDirectHLSFallbackLeavesBothRatesUnavailable() async throws {
    let meter = DownloadTransferMeter()
    let gate = HLSPromotionGate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let manager = CacheManager(
        root: root.appendingPathComponent("direct-hls-videos"),
        configuration: configuration,
        fileManager: .default,
        streamCache: streamCache,
        transferMeter: meter,
        beforeExternalPromotion: { await gate.waitForRelease() }
    )
    MockURLProtocol.stub(
        path: "/videos/18/hls/master.m3u8",
        data: Data("#EXTM3U\nvideo.m3u8\n".utf8)
    )
    MockURLProtocol.stub(
        path: "/videos/18/hls/video.m3u8",
        data: Data("#EXTM3U\n#EXTINF:6,\nsegment.m4s\n".utf8)
    )
    MockURLProtocol.stub(
        path: "/videos/18/hls/segment.m4s",
        data: Data([1, 2, 3])
    )
    let download = Task {
        try await manager.downloadHLS(
            id: 18,
            masterURL: URL(
                string: "https://u.test/videos/18/hls/master.m3u8"
            )!,
            bearerToken: "tok"
        )
    }

    await gate.waitUntilEntered()
    let activity = try XCTUnwrap(manager.activeDownloads().first)
    XCTAssertNil(meter.generation(for: "18"))
    XCTAssertNil(activity.bytesPerSecond)
    XCTAssertNil(activity.cacheBytesPerSecond)
    await gate.release()
    try await download.value
}
```

- [ ] **Step 2: Run HLS CacheManager tests and verify RED**

```bash
rtk swift test --filter CacheManagerHLSTests
```

Expected: compile failure for the new initializer and `proxyMasterURL`.

- [ ] **Step 3: Inject and overlay the meter**

Add:

```swift
private let transferMeter: DownloadTransferMeter?
private var transferGenerations: [String: DownloadTransferGeneration] = [:]

private func beginTransferMeter(key: String, enabled: Bool) {
    guard enabled, let transferMeter else { return }
    let generation = transferMeter.begin(key: key, now: now())
    lock.withLock { transferGenerations[key] = generation }
}

private func endTransferMeter(key: String) {
    let generation = lock.withLock {
        transferGenerations.removeValue(forKey: key)
    }
    if let generation {
        transferMeter?.end(key: key, generation: generation)
    }
}
```

Rewrite `activeDownloads()` so it copies base activities under the CacheManager
lock, releases that lock, then snapshots the meter:

```swift
public func activeDownloads() -> [DownloadActivity] {
    let activities = lock.withLock {
        inFlight.values.map(\.activity).sorted { $0.id < $1.id }
    }
    return activities.map { activity in
        guard let snapshot = transferMeter?.snapshot(
            key: activity.id,
            now: now()
        ) else {
            return activity
        }
        return activity.applying(snapshot)
    }
}
```

This lock ordering is mandatory: never call the meter while holding
`CacheManager.lock`.

- [ ] **Step 4: Select the proxy HLS source and skip direct cache reuse**

Add `proxyMasterURL` and resolve:

```swift
let downloadMasterURL = proxyMasterURL ?? masterURL
let proxyManaged = proxyMasterURL != nil
```

Use `downloadMasterURL` for the master and every relative asset URL. Set:

```swift
let segmentCache = proxyManaged ? nil : streamSegmentCache
```

Only call `beginTransferMeter` after `beginExternalActivity` succeeds. Call
`endTransferMeter` from all terminal external paths:

- `endExternalActivity`
- `cancelExternalActivity`
- successful `promoteExternalActivity`

Use generation-aware `end` so a late old completion cannot clear a replacement.

- [ ] **Step 5: Remove old accumulator timing parameters**

Update every `DownloadActivityAccumulator` initializer and `record` call in
`CacheManager.swift` and `CacheManager+HLS.swift`. Remove the legacy baseline
call from `urlSession(_:downloadTask:didWriteData:...)`; progress callbacks
still update percentage and transferred bookkeeping.

- [ ] **Step 6: Run HLS and activity tests**

```bash
rtk swift test --filter CacheManagerHLSTests
rtk swift test --filter DownloadActivityTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift
rtk git commit -m "feat(ios): source HLS download rates from proxy"
```

---

### Task 7: Proxy-aware MP4 attempts and relaunch-safe resume

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift`

**Interfaces:**
- Consumes: stable upstream URL, current proxy MP4 URL, shared meter.
- Produces:
  - `download(..., proxyURL: URL? = nil, ...)`
  - `resumeInterrupted(bearerToken:proxyURL:)`
  - `SegmentedAttempt.requestURL`
  - stable `SegmentedDownloadManifest.remoteURL`.

- [ ] **Step 1: Add failing initial-attempt and seed-bypass tests**

```swift
@Test func proxyManagedMP4PersistsUpstreamButRequestsProxy() async throws {
    let payload = Data("abcdefghijkl".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    let upstream = URL(string: "https://srv.test/videos/71/stream")!
    let proxy = URL(string: "http://127.0.0.1:43123/s/download/mp4/71/0")!
    RangeDownloadProtocol.setDelays([
        "bytes=0-5": 0.2,
        "bytes=6-11": 0.2,
    ])
    let root = tempRoot()
    let manager = CacheManager(
        root: root,
        configuration: rangeDownloadConfig()
    )
    let store = SegmentedDownloadStore(root: root)

    let task = Task {
        try await manager.download(
            id: 71,
            from: upstream,
            proxyURL: proxy,
            streamCount: 2
        )
    }
    for _ in 0..<100
    where !FileManager.default.fileExists(
        atPath: store.manifestURL(cacheKey: "71").path
    ) {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(try store.load(cacheKey: "71").remoteURL == upstream)
    try await task.value
    let requests = RangeDownloadProtocol.recordedRequests()
    #expect(!requests.isEmpty)
    #expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
}

private actor RecordingStreamCacheSeeder: StreamCacheSeeding {
    private var calls = 0

    func seedSegments(
        manifest: SegmentedDownloadManifest,
        into store: SegmentedDownloadStore
    ) async -> SegmentedDownloadManifest {
        calls += 1
        return manifest
    }

    func callCount() -> Int { calls }
}

@Test func proxyManagedMP4SkipsStreamCacheSeeding() async throws {
    let payload = Data("abcdefgh".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    let seeder = RecordingStreamCacheSeeder()
    let manager = CacheManager(
        root: tempRoot(),
        configuration: rangeDownloadConfig(),
        fileManager: .default,
        streamCache: seeder
    )

    try await manager.download(
        id: 71,
        from: URL(string: "https://srv.test/videos/71/stream")!,
        proxyURL: URL(
            string: "http://127.0.0.1:43123/s/download/mp4/71/0"
        )!,
        streamCount: 2
    )

    #expect(await seeder.callCount() == 0)
}

@Test func directMP4FallbackLeavesBothRatesUnavailable() async throws {
    let payload = Data("abcdefghijkl".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    RangeDownloadProtocol.setDelays([
        "bytes=0-5": 0.2,
        "bytes=6-11": 0.2,
    ])
    let meter = DownloadTransferMeter()
    let manager = CacheManager(
        root: tempRoot(),
        configuration: rangeDownloadConfig(),
        transferMeter: meter
    )
    let task = Task {
        try await manager.download(
            id: 74,
            from: URL(string: "https://srv.test/videos/74/stream")!,
            streamCount: 2
        )
    }
    for _ in 0..<100 where manager.activeDownloads().isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }

    let activity = try #require(manager.activeDownloads().first)
    #expect(meter.generation(for: "74") == nil)
    #expect(activity.bytesPerSecond == nil)
    #expect(activity.cacheBytesPerSecond == nil)
    try await task.value
}
```

- [ ] **Step 2: Add failing relaunch tests**

```swift
@Test func resumeInterruptedUsesCurrentProxyURLNotPersistedUpstream() async throws {
    let payload = Data("abcdefghijkl".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    let root = tempRoot()
    let upstream = URL(string: "https://srv.test/videos/72/stream")!
    let currentProxy = URL(
        string: "http://127.0.0.1:53211/new/download/mp4/72/0"
    )!
    let store = SegmentedDownloadStore(root: root)
    let manifest = try SegmentedDownloadManifest.make(
        videoId: 72,
        versionId: nil,
        remoteURL: upstream,
        requestedStreamCount: 3,
        totalByteCount: Int64(payload.count),
        etag: "\"test-video\""
    )
    try store.write(manifest)
    let manager = CacheManager(
        root: root,
        configuration: rangeDownloadConfig()
    )

    #expect(manager.resumeInterrupted(
        bearerToken: "tok",
        proxyURL: { id, version in
            #expect(id == 72)
            #expect(version == nil)
            return currentProxy
        }
    ) == [72])
    for _ in 0..<500 where manager.state(for: 72) != .cached {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(manager.state(for: 72) == .cached)
    let requests = RangeDownloadProtocol.recordedRequests()
    #expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
    #expect(requests.allSatisfy {
        $0.url?.path == "/new/download/mp4/72/0"
    })
    #expect(try Data(contentsOf: manager.localURL(for: 72)) == payload)
}

@Test func proxyRelaunchDropsStaleResumeBlobButKeepsDurablePart() async throws {
    let payload = Data("abcdefghijkl".utf8)
    RangeDownloadProtocol.reset(payload: payload)
    let root = tempRoot()
    let store = SegmentedDownloadStore(root: root)
    var manifest = try SegmentedDownloadManifest.make(
        videoId: 73,
        versionId: nil,
        remoteURL: URL(string: "https://srv.test/videos/73/stream")!,
        requestedStreamCount: 3,
        totalByteCount: Int64(payload.count),
        etag: "\"test-video\""
    )
    manifest.segments[0].isComplete = true
    manifest.segments[0].persistedByteCount = 4
    try store.write(manifest)
    try payload.subdata(in: 0..<4).write(
        to: store.partURL(cacheKey: "73", index: 0)
    )
    try Data("old-loopback-resume".utf8).write(
        to: store.resumeURL(cacheKey: "73", index: 1)
    )
    let manager = CacheManager(
        root: root,
        configuration: rangeDownloadConfig()
    )

    #expect(manager.resumeInterrupted(
        proxyURL: { _, _ in
            URL(string: "http://127.0.0.1:53212/download/mp4/73/0")
        }
    ) == [73])
    for _ in 0..<500 where manager.state(for: 73) != .cached {
        try await Task.sleep(for: .milliseconds(10))
    }

    let ranges = Set(
        RangeDownloadProtocol.recordedRequests().compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
    )
    #expect(!ranges.contains("bytes=0-3"))
    #expect(ranges == Set(["bytes=4-7", "bytes=8-11"]))
    #expect(try Data(contentsOf: manager.localURL(for: 73)) == payload)
}
```

- [ ] **Step 3: Run focused tests and verify RED**

```bash
rtk swift test --filter CacheManagerTests
```

Expected: compile failure for `proxyURL` arguments and request URL separation.

- [ ] **Step 4: Separate stable manifest URL from live request URL**

Extend `SegmentedAttempt`:

```swift
let requestURL: URL

init(
    cacheKey: String,
    bearerToken: String?,
    manifest: SegmentedDownloadManifest,
    requestURL: URL,
    continuation: CheckedContinuation<URL, Error>?
) {
    self.cacheKey = cacheKey
    self.bearerToken = bearerToken
    self.manifest = manifest
    self.requestURL = requestURL
    self.continuation = continuation
}
```

Thread `requestURL` through both `startSegmentedAttempt` overloads. Replace only
network request construction in `startIncompleteSegments` and
`relaunchSegment`:

```swift
var request = URLRequest(url: attempt.requestURL)
```

Do not change `manifest.remoteURL`; `SegmentedDownloadManifest.make` always
receives the stable upstream `remote`.

- [ ] **Step 5: Add proxy-aware fresh MP4 source selection**

Change the public API:

```swift
public func download(
    id: Int,
    versionId: Int? = nil,
    from remote: URL,
    proxyURL: URL? = nil,
    preview: URL? = nil,
    showPosterKey: String? = nil,
    showPoster: URL? = nil,
    bearerToken: String? = nil,
    streamCount: Int = 1
) async throws
```

Inside `downloadVideo`, use:

```swift
let requestURL = proxyURL ?? remote
let proxyManaged = proxyURL != nil
```

Probe `requestURL`, make the manifest with `remote`, skip `seedSegments` when
`proxyManaged`, and begin the meter only after successfully claiming `inFlight`.
Every terminal MP4 path (`completeSegmentedClaim`, `finish`, explicit cancel,
probe failure) must end the exact stored generation.

- [ ] **Step 6: Make relaunch resolve a current proxy**

Use:

```swift
public func resumeInterrupted(
    bearerToken: String? = nil,
    proxyURL: ((Int, Int?) -> URL?)? = nil
) -> [Int]
```

For each manifest:

```swift
let currentProxyURL = proxyURL?(manifest.videoId, manifest.versionId)
let requestURL = currentProxyURL ?? manifest.remoteURL
```

If `currentProxyURL != nil`, remove every incomplete segment's `.resume` file
before `startIncompleteSegments`; opaque resume data embeds the previous
loopback endpoint. Leave completed part files and manifest completion flags
untouched. Start the meter for proxy resumes after ownership registration.

Legacy root-level `.resume` files have no stable manifest URL. Keep their
existing direct resume behavior and leave their rates unavailable.

- [ ] **Step 7: Run segmented-download and CacheManager tests**

```bash
rtk swift test --filter SegmentedDownloadTests
rtk swift test --filter CacheManagerTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift ios/PatataTubeKit/Sources/PatataTubeKit/SegmentedDownload.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/SegmentedDownloadTests.swift
rtk git commit -m "feat(ios): route resumable MP4 downloads through proxy"
```

---

### Task 8: Share the meter and proxy URLs in the app

**Files:**
- Modify: `ios/PatataTube/Sources/AppModel.swift`
- Modify: `ios/PatataTube/Sources/VideoGridView.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift`
- Modify: `ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift`

**Interfaces:**
- Consumes: proxy URL builders and CacheManager proxy URL parameters.
- Produces:
  - one shared `DownloadTransferMeter` per `AppModel`;
  - current HLS/MP4 download proxy URLs at tap and resume time.

- [ ] **Step 1: Add URL-builder identity tests**

```swift
func testDownloadURLsKeepVideoAndVersionIdentity() async throws {
    let hls = try XCTUnwrap(
        proxy.downloadHLSURL(videoId: 5, versionId: 12)
    )
    let mp4 = try XCTUnwrap(
        proxy.downloadMP4URL(videoId: 5, versionId: 12)
    )
    XCTAssertTrue(hls.path.contains("/download/hls/5/12/master.m3u8"))
    XCTAssertTrue(mp4.path.contains("/download/mp4/5/12"))
}
```

- [ ] **Step 2: Run the URL test**

```bash
rtk swift test --filter StreamProxyTests/testDownloadURLsKeepVideoAndVersionIdentity
```

Expected: PASS if Tasks 3 and 4 preserved version identity; otherwise fix the
builders before app wiring.

- [ ] **Step 3: Share one meter in `AppModel`**

Construct locals before assigning stored properties:

```swift
let transferMeter = DownloadTransferMeter()
let streamCache = StreamCache()
let cache = CacheManager(
    root: cacheRoot,
    streamCache: streamCache,
    transferMeter: transferMeter
)
let streamProxy = StreamProxy(
    cache: streamCache,
    credentials: credentials,
    offlineRoot: cache.videosRoot,
    transferMeter: transferMeter
)
self.streamCache = streamCache
self.cache = cache
self.streamProxy = streamProxy
```

Add:

```swift
func downloadHLSURL(for video: Video) -> URL? {
    guard video.hlsPath?.isEmpty == false else { return nil }
    return streamProxy.downloadHLSURL(
        videoId: video.id,
        versionId: video.chosenVersionId
    )
}

func downloadMP4URL(for video: Video) -> URL? {
    streamProxy.downloadMP4URL(
        videoId: video.id,
        versionId: video.chosenVersionId
    )
}
```

- [ ] **Step 4: Pass stable and proxy URLs from `VideoGridView`**

HLS:

```swift
try await model.cache.downloadHLS(
    id: target.id,
    versionId: target.chosenVersionId,
    masterURL: master,
    proxyMasterURL: model.downloadHLSURL(for: target),
    preview: preview,
    showPosterKey: posterKey,
    showPoster: poster,
    bearerToken: model.credentials.token
)
```

MP4:

```swift
try await model.cache.download(
    id: target.id,
    versionId: target.chosenVersionId,
    from: url,
    proxyURL: model.downloadMP4URL(for: target),
    preview: preview,
    showPosterKey: posterKey,
    showPoster: poster,
    bearerToken: model.credentials.token,
    streamCount: model.downloadStreamCount
)
```

- [ ] **Step 5: Resolve current proxy URLs during app activation**

```swift
model.cache.resumeInterrupted(
    bearerToken: model.credentials.token,
    proxyURL: { id, versionId in
        model.streamProxy.downloadMP4URL(
            videoId: id,
            versionId: versionId
        )
    }
)
```

- [ ] **Step 6: Build the package and app**

Run from `ios/PatataTubeKit`:

```bash
rtk swift build
```

Run from `ios`:

```bash
rtk xcodebuild build -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: both exit 0.

- [ ] **Step 7: Commit**

```bash
rtk git add ios/PatataTube/Sources/AppModel.swift ios/PatataTube/Sources/VideoGridView.swift ios/PatataTube/Sources/PatataTubeApp.swift ios/PatataTubeKit/Tests/PatataTubeKitTests/StreamProxyTests.swift
rtk git commit -m "feat(ios): wire offline downloads through stream proxy"
```

---

### Task 9: Dual-rate Downloads row

**Files:**
- Modify: `ios/PatataTube/Sources/DownloadsView.swift`
- Modify: `ios/PatataTube/Tests/DownloadsViewTests.swift`

**Interfaces:**
- Consumes: `DownloadActivity.bytesPerSecond` as network and
  `cacheBytesPerSecond` as cache.
- Produces:
  - `DownloadRateFormatter.value(_:)`
  - `DownloadRateFormatter.text(network:cache:)`
  - exact row copy `Net <rate> · Cache <rate>`.

- [ ] **Step 1: Write failing formatter and row tests**

```swift
@Test func formatterLabelsIndependentNetworkAndCacheRates() {
    #expect(
        DownloadRateFormatter.text(network: 2_500_000, cache: 12_000)
            == "Net 2.5 MB/s · Cache 12 KB/s"
    )
    #expect(
        DownloadRateFormatter.text(network: nil, cache: 12_000)
            == "Net — · Cache 12 KB/s"
    )
    #expect(
        DownloadRateFormatter.text(network: 2_500_000, cache: nil)
            == "Net 2.5 MB/s · Cache —"
    )
}

@Test func activeRowShowsBothRatesAndCancelInvokesIdentity() async throws {
    var cancelled: DownloadActivity.ID?
    let activity = DownloadActivity(
        videoID: 7,
        versionID: 2,
        progress: 0.5,
        transferredByteCount: 5_000,
        totalByteCount: 10_000,
        bytesPerSecond: 1_500,
        cacheBytesPerSecond: 8_000
    )
    let sut = DownloadsView(
        active: { [activity] },
        recent: { [] },
        video: { id, _ in sampleVideo(id: id) },
        onCancel: { cancelled = $0.id },
        onPlay: { _ in }
    )

    let inspected = try sut.inspect()
    #expect(
        try inspected.find(text: "Net 1.5 KB/s · Cache 8 KB/s").string()
            == "Net 1.5 KB/s · Cache 8 KB/s"
    )
    try inspected.find(button: "Cancel").tap()
    #expect(cancelled == activity.id)
}
```

Add an accessibility inspection that asserts the combined value contains both
`Net` and `Cache`; use the same ViewInspector accessibility API already used by
the app tests rather than snapshotting rendered pixels.

- [ ] **Step 2: Run UI tests and verify RED**

Run from `ios`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadsViewTests
```

Expected: compile failure for the new formatter API or failure finding the dual
label.

- [ ] **Step 3: Implement exact formatting and row copy**

```swift
enum DownloadRateFormatter {
    static func value(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "—" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
                .replacingOccurrences(of: ".0 MB/s", with: " MB/s")
        }
        return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
            .replacingOccurrences(of: ".0 KB/s", with: " KB/s")
    }

    static func text(network: Double?, cache: Double?) -> String {
        "Net \(value(network)) · Cache \(value(cache))"
    }
}
```

In `activeRow`:

```swift
let rate = DownloadRateFormatter.text(
    network: item.bytesPerSecond,
    cache: item.cacheBytesPerSecond
)
```

Keep one monospaced `Text(rate)` in the existing row and use the same string as
the combined accessibility value.

- [ ] **Step 4: Run focused UI tests**

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -only-testing:PatataTubeTests/DownloadsViewTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add ios/PatataTube/Sources/DownloadsView.swift ios/PatataTube/Tests/DownloadsViewTests.swift
rtk git commit -m "feat(ios): show network and cache download rates"
```

---

### Task 10: Full regression verification and investigation-note closure

**Files:**
- Modify: `docs/stream-possible-ways-can-affect-download-measurement.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: verified package/app behavior and a short resolution note explaining
  that speed no longer derives from HLS progress units.

- [ ] **Step 1: Update the investigation note**

Add a dated resolution section at the top:

```markdown
## Resolution (2026-07-26)

Offline downloads now use dedicated `StreamProxy` routes. The Downloads page
shows two non-overlapping trailing rates: upstream response-body bytes as
`Net`, and bytes served from pre-existing `StreamCache` storage as `Cache`.
HLS's 10,000-unit counter remains percentage-only and no longer feeds a speed.
Playback traffic is excluded, and inactive rates decay to an em dash after the
2.5-second window.
```

Keep the rest of the document as historical investigation context.

- [ ] **Step 2: Run the complete PatataTubeKit suite**

Run from `ios/PatataTubeKit`:

```bash
rtk swift test
```

Expected: exit 0 with no failed tests.

- [ ] **Step 3: Run the complete iOS app suite**

Run from `ios`:

```bash
rtk xcodebuild test -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1'
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Verify the final diff**

Run from repository root:

```bash
rtk git status --short
rtk git diff --check
rtk git diff --stat HEAD~9
```

Expected: only files named in this plan are changed; `git diff --check` exits 0.
If the worktree had unrelated user changes before execution, exclude them from
the task's commits and report them separately.

- [ ] **Step 5: Commit the resolution note**

Because `docs/` is ignored for new additions but this file already exists, use
normal add first; use `-f` only if Git still reports the path as ignored:

```bash
rtk git add docs/stream-possible-ways-can-affect-download-measurement.md
rtk git commit -m "docs(ios): document proxy download rate measurement"
```

- [ ] **Step 6: Manual acceptance checks**

On a device or simulator connected to a real server:

1. Cold-download a large HLS video. Confirm `Net` reflects server traffic and
   `Cache` remains `—`.
2. Play enough of the same HLS video to warm several assets, then download it.
   Confirm both rates appear and completion time remains correct.
3. Warm an MP4 prefix through playback, then download it with four streams.
   Confirm cache bytes appear without double-counting newly fetched bytes.
4. Pause traffic for more than 2.5 seconds. Confirm the inactive source changes
   to `—` instead of retaining a stale value.
5. Start an MP4 download, background/terminate the app, relaunch, and confirm
   only incomplete ranges resume through the new loopback port.
6. Play the same video while it downloads. Confirm playback traffic does not
   inflate either offline-download rate.
7. Disable or fail stream-cache writes. Confirm the download continues and the
   affected bytes appear only under `Net`.
