import Foundation
import os

/// Where drained records go. `DevLog` fans out to every installed sink.
public protocol DevLogSink: Sendable {
    /// Always called off the caller's thread, oldest record first.
    func write(_ records: [DevLogRecord])
}

/// Structured, agent-readable runtime instrumentation.
///
/// Off by default. The whole thing is inert unless the app is compiled with the
/// `DEVLOG` condition (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEVLOG'`,
/// injected by `ios/ipa_builder.rb --instrumented` and by the Debug config for
/// Simulator runs). `DEVLOG` is deliberately independent of `DEBUG`: the build
/// that actually misbehaves is the Release `.ipa` sideloaded through AltStore.
///
/// Call sites look like:
///
///     DevLog.event(.play, "item status -> failed", ["video_id": "\(id)", "err": "\(code)"])
///
/// Both arguments are `@autoclosure`, so with `DEVLOG` off nothing is
/// interpolated, allocated, or formatted — the `enabled` check comes first.
///
/// **Instrumentation must never be the bug.** This app has already shipped a
/// main-thread hang from a synchronous `NSFileHandle.write` (see the note at
/// `VideoStore.swift:100`, Sentry PATATATUBE-2). Emission therefore only takes a
/// lock and appends to a bounded ring buffer; all I/O happens later on a utility
/// queue, and overflow drops records rather than applying backpressure to the
/// playback path.
public enum DevLog {
    public enum Kind: String, Codable, Sendable {
        case tap        // user touched something
        case nav        // screen / route change
        case play       // AVPlayer + AVPlayerItem state machine
        case proxy      // StreamProxy request handling
        case cache      // CacheState transitions, evictions, cache mutations
        case download   // download lifecycle, retries, concurrency gate
        case net        // APIClient traffic
        case state      // store / model mutations
        case error
        case lifecycle  // launch, scene phase, memory, log-internal notices
    }

    /// Resolved once, from the compilation condition. Kept out of the inlinable
    /// bodies below so `#if` is never evaluated in a client's context.
    ///
    /// Public so callers can skip setting up instrumentation machinery of their
    /// own — `PlaybackProbe` registers no KVO observers at all when this is
    /// false. Baked into the library at its compile time, so it is the library's
    /// build, not the caller's, that decides.
    public static let enabled: Bool = {
        #if DEVLOG
        return true
        #else
        return false
        #endif
    }()

    @usableFromInline
    static let core = DevLogCore()

    /// Identifies this app run. Present on every record.
    public static var session: String { core.session }

    /// Free space on the volume backing the app's storage, in bytes, as a
    /// string (`"-"` if unavailable).
    ///
    /// Several suspected failure modes are disk-pressure driven — segmented
    /// assembly needs roughly twice the movie's size free at the moment it
    /// finishes, and the proxy cache degenerates into an evict/refetch loop on
    /// ENOSPC — so free space is recorded alongside the events that would be
    /// caused by running out of it.
    public static func freeDiskBytes() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return "-" }
        return "\(available)"
    }

    /// Canonical rendering of a `CacheState` for `meta`. One spelling everywhere
    /// so the agent can group on it.
    public static func describe(_ state: CacheState) -> String {
        switch state {
        case .notCached: return "notCached"
        case .cached: return "cached"
        case .downloading(let fraction): return String(format: "downloading(%.2f)", fraction)
        }
    }

    // MARK: - Emitting

    @inlinable
    public static func event(
        _ kind: Kind,
        _ message: @autoclosure () -> String,
        _ meta: @autoclosure () -> [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        guard enabled else { return }
        core.emit(kind: kind, message: message(), meta: meta(),
                  file: file, line: line, function: function)
    }

    /// An `Error` with optional context. Flushed eagerly — if the app is about
    /// to die, this is the record worth having on disk.
    @inlinable
    public static func error(
        _ error: some Error,
        _ context: @autoclosure () -> String = "",
        _ meta: @autoclosure () -> [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        guard enabled else { return }
        let ctx = context()
        var m = meta()
        m["type"] = String(describing: type(of: error))
        if let ns = error as NSError? {
            m["domain"] = ns.domain
            m["code"] = "\(ns.code)"
        }
        core.emit(kind: .error, message: ctx.isEmpty ? "\(error)" : "\(ctx): \(error)",
                  meta: m, file: file, line: line, function: function)
    }

    /// Function-entry trace: `DevLog.call(["video_id": "\(id)"])`.
    @inlinable
    public static func call(
        _ meta: @autoclosure () -> [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        guard enabled else { return }
        core.emit(kind: .state, message: function, meta: meta(),
                  file: file, line: line, function: function)
    }

    // MARK: - Lifecycle

    /// Installs the sinks and records the launch marker. Safe to call when
    /// disabled (does nothing) and safe to call more than once.
    public static func start() {
        guard enabled else { return }
        core.installDefaultSinks()
        core.emit(kind: .lifecycle, message: "=== launch ===",
                  meta: ["session": core.session],
                  file: #fileID, line: #line, function: #function)
        core.flush()
    }

    public static func install(sink: DevLogSink) {
        core.install(sink: sink)
    }

    /// Points the HTTP sink at the backend. Call once credentials are known and
    /// again whenever they change — on a real device this is the only sink, so
    /// nothing is recorded off-simulator until this runs.
    ///
    /// Records emitted before this are not lost: they sit in the ring buffer and
    /// go out with the first batch, unless the buffer overflows first (which is
    /// reported as a drop marker).
    public static func connect(baseURL: URL?, token: String?) {
        guard enabled, let baseURL, let token, !token.isEmpty else { return }
        core.connectHTTP(baseURL: baseURL, token: token)
    }

    /// Drains pending records to the sinks. Call on `willResignActive` and
    /// before anything that might terminate the process.
    public static func flush() {
        guard enabled else { return }
        core.flush()
    }
}

// MARK: - Core

/// The always-compiled machinery behind `DevLog`. Compiled in regardless of the
/// `DEVLOG` condition so it stays unit-testable with a plain `swift test`; only
/// the call sites in `DevLog` are gated.
@usableFromInline
final class DevLogCore: @unchecked Sendable {
    /// ~4k records is a few minutes of a busy playback session. Past that the
    /// oldest go, and the gap is reported.
    static let defaultCapacity = 4096
    /// Records buffered before an early flush is triggered instead of waiting
    /// out the interval.
    static let flushThreshold = 256
    static let flushInterval: TimeInterval = 1.0

    let session: String
    private let lock = NSLock()
    private let ring: DevLogRingBuffer
    private var seq: UInt64 = 0
    private var sinks: [DevLogSink] = []
    private var flushScheduled = false
    private var defaultSinksInstalled = false
    /// Held apart from `sinks` so re-connecting with new credentials replaces
    /// the old endpoint instead of stacking a second one.
    private var httpSink: DevLogHTTPSink?
    private var httpTarget: String?

    private let queue = DispatchQueue(label: "com.patatatube.devlog", qos: .utility)
    private let mirror = Logger(subsystem: "com.patatatube.app", category: "devlog")

    init(capacity: Int = DevLogCore.defaultCapacity, session: String = UUID().uuidString) {
        self.ring = DevLogRingBuffer(capacity: capacity)
        self.session = session
    }

    @usableFromInline
    func emit(
        kind: DevLog.Kind,
        message: String,
        meta: [String: String],
        file: String,
        line: Int,
        function: String
    ) {
        // os_log first and unconditionally: it is buffered by the system and
        // survives every sink being unreachable, so Console.app / `log stream`
        // still shows the run.
        mirror.log("\(kind.rawValue, privacy: .public) \(message, privacy: .public)")

        let record: DevLogRecord
        var shouldFlushNow = false
        lock.lock()
        seq &+= 1
        record = DevLogRecord(
            ts: Date(), seq: seq, session: session, kind: kind, msg: message,
            src: "\(file):\(line)", fn: function, meta: meta
        )
        ring.append(record)
        if kind == .error || ring.pendingCount >= Self.flushThreshold {
            shouldFlushNow = true
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                self?.drainAndWrite()
            }
        }
        lock.unlock()

        if shouldFlushNow {
            queue.async { [weak self] in self?.drainAndWrite() }
        }
    }

    func install(sink: DevLogSink) {
        lock.lock()
        sinks.append(sink)
        lock.unlock()
    }

    func connectHTTP(baseURL: URL, token: String) {
        let target = "\(baseURL.absoluteString)|\(token.hashValue)"
        lock.lock()
        guard httpTarget != target else { lock.unlock(); return }
        httpTarget = target
        httpSink = DevLogHTTPSink(baseURL: baseURL, token: token, sessionID: session)
        lock.unlock()

        emit(kind: .lifecycle, message: "devlog sink -> \(baseURL.absoluteString)",
             meta: [:], file: #fileID, line: #line, function: #function)
    }

    func installDefaultSinks() {
        lock.lock()
        let alreadyDone = defaultSinksInstalled
        defaultSinksInstalled = true
        lock.unlock()
        guard !alreadyDone else { return }

        // Simulator: the app can write straight to the host filesystem, so the
        // path is handed in by the scheme. On device this is absent and the HTTP
        // sink carries the log instead.
        if let path = ProcessInfo.processInfo.environment["PATATATUBE_DEV_LOG"],
           let sink = DevLogFileSink(path: path) {
            install(sink: sink)
        }
    }

    func flush() {
        queue.async { [weak self] in self?.drainAndWrite() }
    }

    /// Test seam: drains synchronously on the calling thread.
    func drainAndWrite() {
        lock.lock()
        flushScheduled = false

        var currentSinks = sinks
        if let httpSink { currentSinks.append(httpSink) }
        // Nothing to drain into yet — on a real device that is every record
        // before `connect` supplies credentials. Leave them in the ring so they
        // go out with the first batch; the ring's own overflow (reported as a
        // drop marker) is the only thing allowed to discard them.
        guard !currentSinks.isEmpty else { lock.unlock(); return }

        let (records, dropped) = ring.drain()
        lock.unlock()

        guard !records.isEmpty || dropped > 0 else { return }

        var batch: [DevLogRecord] = []
        batch.reserveCapacity(records.count + 1)
        if dropped > 0 {
            // A gap in `seq` must never be silent — an agent reading the log has
            // to be able to tell "this didn't happen" from "this was discarded".
            batch.append(DevLogRecord(
                ts: Date(), seq: 0, session: session, kind: .lifecycle,
                msg: "dropped \(dropped) record(s) — ring buffer overflow",
                src: "DevLog.swift", fn: "drainAndWrite()",
                meta: ["dropped": "\(dropped)"]
            ))
        }
        batch.append(contentsOf: records)

        for sink in currentSinks {
            sink.write(batch)
        }
    }
}
