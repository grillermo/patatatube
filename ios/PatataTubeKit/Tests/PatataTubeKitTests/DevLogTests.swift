import XCTest
@testable import PatataTubeKit

/// Collects batches instead of writing them anywhere.
private final class SpySink: DevLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[DevLogRecord]] = []

    var allRecords: [DevLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return batches.flatMap { $0 }
    }

    func write(_ records: [DevLogRecord]) {
        lock.lock(); defer { lock.unlock() }
        batches.append(records)
    }
}

final class DevLogRingBufferTests: XCTestCase {
    private func record(_ seq: UInt64) -> DevLogRecord {
        DevLogRecord(ts: Date(timeIntervalSince1970: 0), seq: seq, session: "s",
                     kind: .state, msg: "m\(seq)", src: "f.swift:1", fn: "f()", meta: [:])
    }

    func testDrainsInInsertionOrder() {
        let ring = DevLogRingBuffer(capacity: 4)
        (1...3).forEach { ring.append(record(UInt64($0))) }

        let (records, dropped) = ring.drain()

        XCTAssertEqual(records.map(\.seq), [1, 2, 3])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(ring.pendingCount, 0)
    }

    func testOverflowDropsOldestAndCountsIt() {
        let ring = DevLogRingBuffer(capacity: 3)
        (1...5).forEach { ring.append(record(UInt64($0))) }

        let (records, dropped) = ring.drain()

        XCTAssertEqual(records.map(\.seq), [3, 4, 5], "oldest records go first")
        XCTAssertEqual(dropped, 2)
    }

    func testDrainResetsDropCount() {
        let ring = DevLogRingBuffer(capacity: 1)
        ring.append(record(1))
        ring.append(record(2))
        _ = ring.drain()

        ring.append(record(3))
        let (records, dropped) = ring.drain()

        XCTAssertEqual(records.map(\.seq), [3])
        XCTAssertEqual(dropped, 0)
    }

    func testWrapsRepeatedlyAcrossDrains() {
        let ring = DevLogRingBuffer(capacity: 2)
        for round in 0..<3 {
            ring.append(record(UInt64(round * 2 + 1)))
            ring.append(record(UInt64(round * 2 + 2)))
            let (records, dropped) = ring.drain()
            XCTAssertEqual(records.map(\.seq), [UInt64(round * 2 + 1), UInt64(round * 2 + 2)])
            XCTAssertEqual(dropped, 0)
        }
    }

    func testEmptyDrainIsCheap() {
        let ring = DevLogRingBuffer(capacity: 4)
        let (records, dropped) = ring.drain()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(dropped, 0)
    }
}

final class DevLogRecordEncodingTests: XCTestCase {
    func testEncodesOneReadableJSONLine() throws {
        let record = DevLogRecord(
            ts: Date(timeIntervalSince1970: 1_700_000_000.123),
            seq: 42, session: "SESSION", kind: .play, msg: "item status -> failed",
            src: "VideoPlayerView.swift:187", fn: "playWhenReady(item:on:)",
            meta: ["video_id": "812", "source": "proxy_mp4"]
        )

        let data = try XCTUnwrap(record.jsonLine(using: DevLogEncoding.makeEncoder()))
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(line.contains("\n"), "a record must be exactly one JSONL line")
        XCTAssertTrue(
            line.hasPrefix("{\"ts\":\"2023-11-14T22:13:20.123Z\",\"seq\":42,\"kind\":\"play\""),
            "leading fields must be stable so a raw tail is readable: \(line)"
        )
        XCTAssertTrue(
            line.contains("\"meta\":{\"source\":\"proxy_mp4\",\"video_id\":\"812\"}"),
            "meta keys must be sorted: \(line)"
        )

        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(decoded["ts"] as? String, "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(decoded["seq"] as? UInt64, 42)
        XCTAssertEqual(decoded["session"] as? String, "SESSION")
        XCTAssertEqual(decoded["kind"] as? String, "play")
        XCTAssertEqual(decoded["msg"] as? String, "item status -> failed")
        XCTAssertEqual(decoded["src"] as? String, "VideoPlayerView.swift:187")
        XCTAssertEqual(decoded["fn"] as? String, "playWhenReady(item:on:)")
        XCTAssertEqual(decoded["meta"] as? [String: String],
                       ["video_id": "812", "source": "proxy_mp4"])
    }

    func testEscapesControlCharactersAndQuotes() throws {
        let record = DevLogRecord(
            ts: Date(timeIntervalSince1970: 0), seq: 1, session: "s", kind: .error,
            msg: "bad \"quote\"\nand newline\ttab \u{1}ctrl é 😀 back\\slash",
            src: "f.swift:1", fn: "f()",
            meta: ["k": "a\nb", "brace": "}{"]
        )

        let data = try XCTUnwrap(record.jsonLine(using: DevLogEncoding.makeEncoder()))
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(line.contains("\n"), "embedded newlines must not split the line")

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["msg"] as? String,
                       "bad \"quote\"\nand newline\ttab \u{1}ctrl é 😀 back\\slash")
        XCTAssertEqual(decoded["meta"] as? [String: String], ["k": "a\nb", "brace": "}{"])
    }
}

final class DevLogCoreTests: XCTestCase {
    func testEmitAssignsMonotonicSeqAndSharedSession() {
        let core = DevLogCore(session: "SESSION")
        let sink = SpySink()
        core.install(sink: sink)

        for i in 1...3 {
            core.emit(kind: .cache, message: "m\(i)", meta: [:],
                      file: "F.swift", line: i, function: "f()")
        }
        core.drainAndWrite()

        let records = sink.allRecords
        XCTAssertEqual(records.map(\.seq), [1, 2, 3])
        XCTAssertEqual(Set(records.map(\.session)), ["SESSION"])
        XCTAssertEqual(records.map(\.src), ["F.swift:1", "F.swift:2", "F.swift:3"])
    }

    func testOverflowEmitsAVisibleDropMarker() {
        let core = DevLogCore(capacity: 2, session: "SESSION")
        let sink = SpySink()
        core.install(sink: sink)

        for i in 1...5 {
            core.emit(kind: .proxy, message: "m\(i)", meta: [:],
                      file: "F.swift", line: i, function: "f()")
        }
        core.drainAndWrite()

        let records = sink.allRecords
        let marker = try? XCTUnwrap(records.first)
        XCTAssertEqual(marker?.kind, .lifecycle)
        XCTAssertEqual(marker?.meta["dropped"], "3")
        XCTAssertEqual(records.dropFirst().map(\.msg), ["m4", "m5"])
    }

    /// On a device nothing is installed until `connect` supplies credentials.
    /// Records emitted before that must survive to the first batch.
    func testRecordsEmittedBeforeAnySinkAreDeliveredLater() {
        let core = DevLogCore(session: "SESSION")
        core.emit(kind: .state, message: "early", meta: [:],
                  file: "F.swift", line: 1, function: "f()")
        core.drainAndWrite()   // no sink yet — must not discard

        let sink = SpySink()
        core.install(sink: sink)
        core.emit(kind: .state, message: "late", meta: [:],
                  file: "F.swift", line: 2, function: "f()")
        core.drainAndWrite()

        XCTAssertEqual(sink.allRecords.map(\.msg), ["early", "late"])
    }

    func testPreSinkBacklogStillBoundedByCapacity() {
        let core = DevLogCore(capacity: 2, session: "SESSION")
        for i in 1...5 {
            core.emit(kind: .state, message: "m\(i)", meta: [:],
                      file: "F.swift", line: i, function: "f()")
            core.drainAndWrite()
        }

        let sink = SpySink()
        core.install(sink: sink)
        core.drainAndWrite()

        let records = sink.allRecords
        XCTAssertEqual(records.first?.meta["dropped"], "3")
        XCTAssertEqual(records.dropFirst().map(\.msg), ["m4", "m5"])
    }

    func testFanOutToEveryInstalledSink() {
        let core = DevLogCore(session: "SESSION")
        let a = SpySink()
        let b = SpySink()
        core.install(sink: a)
        core.install(sink: b)

        core.emit(kind: .download, message: "m", meta: [:],
                  file: "F.swift", line: 1, function: "f()")
        core.drainAndWrite()

        XCTAssertEqual(a.allRecords.map(\.msg), ["m"])
        XCTAssertEqual(b.allRecords.map(\.msg), ["m"])
    }

    func testConcurrentEmitsAreAllRecordedWithUniqueSeq() {
        let core = DevLogCore(capacity: 4096, session: "SESSION")
        let sink = SpySink()
        core.install(sink: sink)

        DispatchQueue.concurrentPerform(iterations: 500) { i in
            core.emit(kind: .play, message: "m\(i)", meta: [:],
                      file: "F.swift", line: 1, function: "f()")
        }
        core.drainAndWrite()

        let seqs = sink.allRecords.map(\.seq)
        XCTAssertEqual(seqs.count, 500)
        XCTAssertEqual(Set(seqs).count, 500, "seq must be unique under concurrency")
    }
}

final class DevLogFileSinkTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "devlog-\(UUID().uuidString)/ios.jsonl"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
    }

    private func record(_ seq: UInt64, _ msg: String) -> DevLogRecord {
        DevLogRecord(ts: Date(timeIntervalSince1970: 0), seq: seq, session: "s",
                     kind: .cache, msg: msg, src: "f.swift:1", fn: "f()", meta: [:])
    }

    func testCreatesIntermediateDirectoriesAndAppendsOneLinePerRecord() throws {
        let sink = try XCTUnwrap(DevLogFileSink(path: path))
        sink.write([record(1, "a"), record(2, "b")])
        sink.write([record(3, "c")])
        sink.close()

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)

        let msgs = try lines.map { line -> String in
            let obj = try JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any]
            return obj?["msg"] as? String ?? ""
        }
        XCTAssertEqual(msgs, ["a", "b", "c"])
    }

    func testAppendsAcrossReopen() throws {
        let first = try XCTUnwrap(DevLogFileSink(path: path))
        first.write([record(1, "a")])
        first.close()

        let second = try XCTUnwrap(DevLogFileSink(path: path))
        second.write([record(2, "b")])
        second.close()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.split(separator: "\n").count, 2)
    }

    func testTruncatesWhenExistingFileExceedsCap() throws {
        let sink = try XCTUnwrap(DevLogFileSink(path: path))
        sink.write([record(1, String(repeating: "x", count: 4096))])
        sink.close()

        let reopened = try XCTUnwrap(DevLogFileSink(path: path, maxBytes: 128))
        reopened.write([record(2, "fresh")])
        reopened.close()

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains("xxxx"), "oversized log should be discarded")
        XCTAssertTrue(contents.contains("fresh"))
    }

    func testWriteAfterCloseIsIgnored() throws {
        let sink = try XCTUnwrap(DevLogFileSink(path: path))
        sink.write([record(1, "a")])
        sink.close()
        sink.write([record(2, "b")])   // must not crash

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains("\"msg\":\"b\""))
    }
}

final class DevLogGatingTests: XCTestCase {
    /// The whole point of the `DEVLOG` condition: a normal build logs nothing.
    /// `swift test` runs without the flag, so `enabled` must be false here and
    /// `event` must not reach any sink.
    func testDisabledUnlessCompiledWithDevlog() {
        #if DEVLOG
        XCTAssertTrue(DevLog.enabled)
        #else
        XCTAssertFalse(DevLog.enabled)
        #endif
    }

    func testEventIsInertWhenDisabled() throws {
        try XCTSkipIf(DevLog.enabled, "only meaningful in a build without DEVLOG")

        let sink = SpySink()
        DevLog.install(sink: sink)

        var interpolationRan = false
        func expensive() -> String { interpolationRan = true; return "should not run" }
        DevLog.event(.play, expensive())
        DevLog.flush()
        DevLog.core.drainAndWrite()

        XCTAssertFalse(interpolationRan, "message autoclosure must not be evaluated")
        XCTAssertTrue(sink.allRecords.isEmpty)
    }

    /// Only runs under `swift test -Xswiftc -DDEVLOG`.
    func testEventReachesSinkWhenEnabled() throws {
        try XCTSkipUnless(DevLog.enabled, "only meaningful in a DEVLOG build")

        let sink = SpySink()
        DevLog.install(sink: sink)
        let marker = "enabled-path-\(UUID().uuidString)"
        DevLog.event(.play, marker, ["video_id": "812"])
        DevLog.core.drainAndWrite()

        let record = try XCTUnwrap(sink.allRecords.first { $0.msg == marker })
        XCTAssertEqual(record.kind, .play)
        XCTAssertEqual(record.meta["video_id"], "812")
        XCTAssertEqual(record.session, DevLog.session)
        XCTAssertTrue(record.src.hasPrefix("PatataTubeKitTests/DevLogTests.swift:"))
    }

    func testErrorCarriesDomainAndCode() throws {
        try XCTSkipUnless(DevLog.enabled, "only meaningful in a DEVLOG build")

        let sink = SpySink()
        DevLog.install(sink: sink)
        let marker = "err-\(UUID().uuidString)"
        DevLog.error(NSError(domain: "AVFoundationErrorDomain", code: -11829), marker)
        DevLog.core.drainAndWrite()

        let record = try XCTUnwrap(sink.allRecords.first { $0.msg.hasPrefix(marker) })
        XCTAssertEqual(record.kind, .error)
        XCTAssertEqual(record.meta["domain"], "AVFoundationErrorDomain")
        XCTAssertEqual(record.meta["code"], "-11829")
    }
}
