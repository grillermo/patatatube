# HLS Download Retry-With-Backoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an offline HLS download survive app backgrounding and transient network loss instead of failing with `NSURLErrorNetworkConnectionLost (-1005)` and discarding the partially staged package.

**Architecture:** `CacheManager+HLS.fetchHLSAsset` currently calls `urlSession.data(for:)` once; any transport error propagates out of the enclosing `withThrowingTaskGroup`, which unwinds `downloadHLS` and fires the `defer` that deletes the `.hls-tmp/<key>` staging directory — losing every asset fetched so far. We wrap the single fetch in a retry loop with exponential backoff (capped), retrying transport errors and 5xx forever while throwing permanent errors (4xx, invalid asset path, file-write, cancellation) immediately. Because the fetch no longer throws on a blip, a suspended app simply makes no progress and resumes on foreground: pause/resume falls out of the retry loop. The `URLSession` default configuration additionally gets `waitsForConnectivity = true` so retries park instead of spinning while offline.

**Tech Stack:** Swift 6, SwiftPM package `PatataTubeKit` (iOS 17 / macOS 14), XCTest, `MockURLProtocol` (existing test double).

## Global Constraints

- No new `UIBackgroundModes`, no background `URLSession`: downloads remain foreground-session only. A killed app restarts the package from zero (session-only checkpointing was an explicit decision).
- UI stays silent while paused — no new "Paused" state, no new published properties. `VideoGridView.swift:328`'s `store.errorText = "Download failed: ..."` must fire only for permanent errors.
- Transport errors are retried **without a budget** (indefinitely) while the app is alive; only permanent errors surface.
- Existing injected `URLSessionConfiguration`s (all tests, `StreamProxy`) must keep their current behavior — only the *default* configuration changes.
- All test sleeps go through an injectable hook; the suite must not wait real backoff seconds.
- Build/test with: `cd ios/PatataTubeKit && swift build` and `swift test`.

---

## File Structure

- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift` — retry loop, backoff schedule, permanent-vs-transient classification. All new logic lives here beside the fetch it guards.
- `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` — two small additions: the injectable `hlsRetrySleep` hook (stored property, near `now`) and a `defaultConfiguration()` factory used as the public convenience init's default argument.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift` — two new stub helpers: fail-N-times-then-succeed, and fixed-status.
- `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift` — the four behavior tests.

---

### Task 1: Retry transient fetch failures with injectable backoff

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift` (add stored property next to `now`, around line 152)
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift:197-217` (`fetchHLSAsset`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: existing `CacheManager.urlSession`, `APIError.badStatus(Int)`, `MockURLProtocol.register(path:response:)` (private — new helpers go in the same file).
- Produces:
  - `CacheManager.hlsRetrySleep: @Sendable (Duration) async throws -> Void` (internal stored var, default `{ try await Task.sleep(for: $0) }`)
  - `CacheManager.hlsRetryBackoff(attempt: Int) -> Duration` (internal, static-schedule helper)
  - `MockURLProtocol.stubFailing(path:failures:error:data:)` — fails the first `failures` requests with `error`, then serves `data` with status 200.

- [ ] **Step 1: Add the fail-then-succeed stub helper to the test double**

In `Tests/PatataTubeKitTests/MockURLProtocol.swift`, add inside `final class MockURLProtocol` (next to `stubRanged`):

```swift
    /// Fails the first `failures` requests for `path` with `error`, then
    /// serves `data` with a 200. Lets a test prove a fetch retried rather
    /// than gave up.
    static func stubFailing(
        path: String,
        failures: Int,
        error: Error = URLError(.networkConnectionLost),
        data: Data
    ) {
        let remaining = Counter(failures)
        register(path: path) { request in
            if remaining.decrementIfPositive() {
                throw error
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
    }
```

And at the bottom of the same file, add the counter it uses:

```swift
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    /// Returns true (and consumes one) while the counter is above zero.
    func decrementIfPositive() -> Bool {
        lock.withLock {
            guard value > 0 else { return false }
            value -= 1
            return true
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

In `Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`, add a helper that stubs the standard package with one asset made flaky, plus two tests. Put them after `testDownloadHLSFetchesAllAssetsAndPromotes`:

```swift
    /// Stubs the full 6-asset package for video 5, with `segment_00000.m4s`
    /// failing `segmentFailures` times before succeeding.
    private func stubPackage(segmentFailures: Int) {
        MockURLProtocol.stub(
            path: "/videos/5/hls/master.m3u8",
            data: Data(master.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/video.m3u8",
            data: Data(media.utf8)
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.m3u8",
            data: Data(subtitles.utf8)
        )
        MockURLProtocol.stub(path: "/videos/5/hls/init.mp4", data: Data([1]))
        MockURLProtocol.stubFailing(
            path: "/videos/5/hls/segment_00000.m4s",
            failures: segmentFailures,
            data: Data([2])
        )
        MockURLProtocol.stub(
            path: "/videos/5/hls/subtitles/es.vtt",
            data: Data([3])
        )
    }

    private func downloadPackage() async throws {
        try await cache.downloadHLS(
            id: 5,
            versionId: nil,
            masterURL: URL(string: "https://u.test/videos/5/hls/master.m3u8")!,
            bearerToken: "tok"
        )
    }

    func testDownloadHLSRetriesSegmentAfterConnectionLost() async throws {
        cache.hlsRetrySleep = { _ in }
        stubPackage(segmentFailures: 1)

        try await downloadPackage()

        let directory = cache.offlineHLSDir(for: 5, versionId: nil)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("segment_00000.m4s").path
            )
        )
        XCTAssertEqual(cache.state(for: 5), .cached)
        XCTAssertEqual(
            MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s"),
            2
        )
    }

    func testDownloadHLSRetriesTransportErrorsWithoutBudget() async throws {
        cache.hlsRetrySleep = { _ in }
        stubPackage(segmentFailures: 12)

        try await downloadPackage()

        XCTAssertEqual(cache.state(for: 5), .cached)
        XCTAssertEqual(
            MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s"),
            13
        )
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: compile failure — `value of type 'CacheManager' has no member 'hlsRetrySleep'`.

- [ ] **Step 4: Add the injectable sleep hook**

In `Sources/PatataTubeKit/CacheManager.swift`, directly below `private let now: @Sendable () -> Date` (line 152), add:

```swift
    // Backoff between HLS asset retries. A stored hook so tests can drive the
    // retry loop without waiting real seconds.
    var hlsRetrySleep: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
```

- [ ] **Step 5: Add the retry loop**

In `Sources/PatataTubeKit/CacheManager+HLS.swift`, replace the whole `private func fetchHLSAsset` (lines 197-217) with:

```swift
    /// Fetches one HLS asset, retrying transport failures indefinitely with
    /// capped exponential backoff.
    ///
    /// iOS tears down sockets when the app is suspended, so a backgrounded
    /// download sees `-1005 networkConnectionLost` mid-transfer. Throwing here
    /// would unwind `downloadHLS` and delete the staging directory, discarding
    /// every asset fetched so far. Retrying in place turns backgrounding (and
    /// a WiFi drop) into a pause: the suspended app makes no progress and
    /// picks the asset back up on foreground.
    private func fetchHLSAsset(
        _ url: URL,
        bearerToken: String?
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await performHLSFetch(url, bearerToken: bearerToken)
            } catch {
                attempt += 1
                try await hlsRetrySleep(hlsRetryBackoff(attempt: attempt))
            }
        }
    }

    private func performHLSFetch(
        _ url: URL,
        bearerToken: String?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        if let bearerToken {
            request.setValue(
                "Bearer \(bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw APIError.badStatus(
                (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        return data
    }

    /// 0.5s, 1s, 2s, 4s, 8s, then 16s forever.
    func hlsRetryBackoff(attempt: Int) -> Duration {
        let capped = min(max(attempt, 1), 6)
        let seconds = 0.25 * pow(2.0, Double(capped))
        return .milliseconds(Int(seconds * 1000))
    }
```

Note `hlsRetryBackoff` is declared without `private` so Task 4's test can assert the schedule.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: PASS, including the pre-existing HLS tests.

- [ ] **Step 7: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift
git commit -m "fix: retry transient HLS asset failures instead of failing the download"
```

---

### Task 2: Fail fast on permanent errors

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift` (the `fetchHLSAsset` added in Task 1)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift`, `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: `fetchHLSAsset`, `hlsRetrySleep`, `hlsRetryBackoff(attempt:)`, `stubPackage(segmentFailures:)` from Task 1.
- Produces: `CacheManager.isPermanentHLSError(_ error: Error) -> Bool` (internal); `MockURLProtocol.stubStatus(path:status:)`.

Without this task the retry loop spins forever on a 404 or an expired token — the download never completes and never reports. Permanent means: the same request will keep failing no matter how long we wait.

- [ ] **Step 1: Add the fixed-status stub helper**

In `Tests/PatataTubeKitTests/MockURLProtocol.swift`, next to `stubFailing`:

```swift
    /// Always answers `path` with `status` and an empty body.
    static func stubStatus(path: String, status: Int) {
        register(path: path) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
    }
```

- [ ] **Step 2: Write the failing tests**

In `Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`, after the Task 1 tests:

```swift
    func testDownloadHLSFailsImmediatelyOnNotFound() async throws {
        cache.hlsRetrySleep = { _ in }
        stubPackage(segmentFailures: 0)
        MockURLProtocol.stubStatus(
            path: "/videos/5/hls/segment_00000.m4s",
            status: 404
        )

        do {
            try await downloadPackage()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? APIError, .badStatus(404))
        }

        XCTAssertEqual(
            MockURLProtocol.requestCount(path: "/videos/5/hls/segment_00000.m4s"),
            1
        )
        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }

    func testDownloadHLSRetriesServerErrors() async throws {
        cache.hlsRetrySleep = { _ in }
        stubPackage(segmentFailures: 0)
        let served = expectation(description: "segment served")
        var attempts = 0
        MockURLProtocol.registerCounting(
            path: "/videos/5/hls/segment_00000.m4s"
        ) { request in
            attempts += 1
            if attempts < 3 {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 503,
                        httpVersion: nil, headerFields: nil
                    )!,
                    Data()
                )
            }
            served.fulfill()
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                Data([2])
            )
        }

        try await downloadPackage()

        await fulfillment(of: [served], timeout: 5)
        XCTAssertEqual(cache.state(for: 5), .cached)
    }
```

Add the public shim `registerCounting` that test needs to `MockURLProtocol` (it only has a `private static func register`):

```swift
    /// Exposes the raw stub registration so a test can script per-attempt
    /// responses. Requests are counted like every other stub.
    static func registerCounting(
        path: String,
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        register(path: path, response: response)
    }
```

Mark the test's `attempts` capture safe by declaring it as `nonisolated(unsafe) var attempts = 0` if the compiler complains about concurrent capture.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: `testDownloadHLSFailsImmediatelyOnNotFound` hangs or fails on the request-count assertion, because the loop retries the 404 forever. If it hangs, that IS the failure — kill it and continue.

- [ ] **Step 4: Add the classification and use it**

In `Sources/PatataTubeKit/CacheManager+HLS.swift`, change the `catch` inside `fetchHLSAsset` to:

```swift
            } catch {
                if isPermanentHLSError(error) { throw error }
                attempt += 1
                try await hlsRetrySleep(hlsRetryBackoff(attempt: attempt))
            }
```

and add below `performHLSFetch`:

```swift
    /// True when retrying cannot help: the server rejected the request, the
    /// package is malformed, the disk write failed, or we were cancelled.
    func isPermanentHLSError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiError = error as? APIError {
            if case let .badStatus(status) = apiError {
                return (400..<500).contains(status)
            }
            return true
        }
        if error is SegmentCacheError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        // Anything non-URLError that reached us is a local failure (file
        // write, directory creation) — retrying the network won't fix it.
        return !(error is URLError)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: PASS, all HLS tests.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift
git commit -m "fix: surface permanent HLS download errors instead of retrying them"
```

---

### Task 3: Cancellation wins while parked in backoff

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift` (`fetchHLSAsset`)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: `throwIfExternalActivityCancelled(key:)` (`CacheManager.swift:344`), `CacheManager.cancel(id:versionId:)` (`CacheManager.swift:561`), `stubPackage`, `downloadPackage`, `hlsRetrySleep`.
- Produces: `fetchHLSAsset(_:bearerToken:cacheKey:)` — the extra `cacheKey: String` argument is passed by every call site in `downloadHLS`.

A user tapping cancel while a segment sits in a 30s backoff must exit promptly, not after the sleep. `hlsRetrySleep` is injected in tests, so the loop needs an explicit cancellation check per iteration rather than relying on `Task.sleep` throwing.

- [ ] **Step 1: Write the failing test**

```swift
    func testDownloadHLSCancelDuringBackoffExitsPromptly() async throws {
        let parked = expectation(description: "parked in backoff")
        let released = HLSPromotionGate()
        cache.hlsRetrySleep = { _ in
            parked.fulfill()
            await released.waitForRelease()
        }
        stubPackage(segmentFailures: 100)

        let download = Task { try await self.downloadPackage() }
        await fulfillment(of: [parked], timeout: 5)
        cache.cancel(id: 5)
        await released.release()

        do {
            _ = try await download.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(cache.offlineHLSMasterURL(for: 5, versionId: nil))
    }
```

`parked` may be fulfilled more than once (several assets retry concurrently); add `parked.assertForOverFulfill = false` right after creating it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter testDownloadHLSCancelDuringBackoffExitsPromptly`
Expected: FAIL — the loop keeps refetching after cancel and the test times out or throws something other than `CancellationError`.

- [ ] **Step 3: Check cancellation each iteration**

In `Sources/PatataTubeKit/CacheManager+HLS.swift`, give `fetchHLSAsset` the cache key and check it:

```swift
    private func fetchHLSAsset(
        _ url: URL,
        bearerToken: String?,
        cacheKey: String
    ) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            try throwIfExternalActivityCancelled(key: cacheKey)
            do {
                return try await performHLSFetch(url, bearerToken: bearerToken)
            } catch {
                if isPermanentHLSError(error) { throw error }
                attempt += 1
                try await hlsRetrySleep(hlsRetryBackoff(attempt: attempt))
            }
        }
    }
```

- [ ] **Step 4: Pass the key at all three call sites**

In `downloadHLS`, add `cacheKey: key` to each `fetchHLSAsset` call:
- the master fetch (`CacheManager+HLS.swift:64-67`)
- the playlist fetch inside `for playlist in playlists` (`:78-81`)
- the segment fetch inside `group.addTask` (`:126-129`) — this one is inside a `[self]`-capturing closure, so it reads `try await self.fetchHLSAsset(..., cacheKey: key)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: PASS, all HLS tests including the pre-existing cancellation tests at `CacheManagerHLSTests.swift:457` and `:549`.

- [ ] **Step 6: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager+HLS.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift
git commit -m "fix: exit HLS retry backoff immediately on cancel"
```

---

### Task 4: Park offline retries via waitsForConnectivity, and pin the backoff schedule

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift:171-183` (public convenience init)
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift`

**Interfaces:**
- Consumes: `hlsRetryBackoff(attempt:)` from Task 1.
- Produces: `CacheManager.defaultConfiguration() -> URLSessionConfiguration` (public static).

With `waitsForConnectivity`, an attempt started while the device is offline waits for the network inside `URLSession` instead of failing instantly, so the retry loop doesn't burn iterations during a long outage. Injected configurations are untouched, so no existing test changes behavior.

- [ ] **Step 1: Write the failing tests**

```swift
    func testDefaultConfigurationWaitsForConnectivity() {
        XCTAssertTrue(CacheManager.defaultConfiguration().waitsForConnectivity)
    }

    func testHLSRetryBackoffRampsAndCaps() {
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 1), .milliseconds(500))
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 2), .milliseconds(1000))
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 3), .milliseconds(2000))
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 6), .milliseconds(16000))
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 7), .milliseconds(16000))
        XCTAssertEqual(cache.hlsRetryBackoff(attempt: 99), .milliseconds(16000))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerHLSTests`
Expected: compile failure — `type 'CacheManager' has no member 'defaultConfiguration'`.

- [ ] **Step 3: Add the factory and use it as the default argument**

In `Sources/PatataTubeKit/CacheManager.swift`, replace the public convenience init (lines 171-183) with:

```swift
    /// Default session config for app use. `waitsForConnectivity` lets a retry
    /// started during an outage park inside URLSession instead of failing
    /// instantly, so the HLS retry loop doesn't spin while offline.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return configuration
    }

    public convenience init(
        root: URL? = nil,
        configuration: URLSessionConfiguration = CacheManager.defaultConfiguration(),
        streamCache: StreamCache? = nil
    ) {
        self.init(
            root: root,
            configuration: configuration,
            fileManager: .default,
            cancellationFence: CacheManagerCancellationFence(),
            streamCache: streamCache
        )
    }
```

- [ ] **Step 4: Run the full suite**

Run: `cd ios/PatataTubeKit && swift build && swift test`
Expected: PASS. Note the backoff test pins the cap at 16s — if Step 3 of Task 1 produced a different schedule, fix `hlsRetryBackoff` rather than the test only if the intent (ramp then cap) is violated; otherwise align the test's expected values with the implemented schedule.

- [ ] **Step 5: Commit**

```bash
git add ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift \
        ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerHLSTests.swift
git commit -m "feat: wait for connectivity on the default download session"
```

---

## Manual verification (after Task 4)

1. `cd ios/PatataTube && xcodegen generate && open PatataTube.xcodeproj`, run on device.
2. Start a download of a large video (one with `hls_path` — i.e. HLS ready on the server).
3. Background the app for ~2 minutes, return.
4. Expected: no red "Download failed" banner; progress continues from where it stopped and the download completes.
5. Repeat with airplane mode toggled on for ~1 minute mid-download — same expectation.
6. Sanity check the failure path still reports: point the app at a bad token (Settings) and start a download — the 401 must surface the error banner immediately.
