import Foundation

/// One line of the dev log.
///
/// Deliberately flat and small: the consumer is a coding agent running `jq` and
/// `grep` over `log/ios.jsonl`, not a dashboard.
public struct DevLogRecord: Equatable, Sendable {
    public let ts: Date
    /// Monotonic within a session. Survives out-of-order delivery once records
    /// are batched over HTTP (the device sink), so the agent can always restore
    /// the true ordering.
    public let seq: UInt64
    /// Identifies one app run. Every record carries it; without it two
    /// interleaved launches in the same file are indistinguishable.
    public let session: String
    public let kind: DevLog.Kind
    public let msg: String
    /// `#fileID:#line` of the call site.
    public let src: String
    /// `#function` of the call site.
    public let fn: String
    public let meta: [String: String]

    public init(
        ts: Date,
        seq: UInt64,
        session: String,
        kind: DevLog.Kind,
        msg: String,
        src: String,
        fn: String,
        meta: [String: String]
    ) {
        self.ts = ts
        self.seq = seq
        self.session = session
        self.kind = kind
        self.msg = msg
        self.src = src
        self.fn = fn
        self.meta = meta
    }
}

public enum DevLogEncoding {
    /// `2026-07-30T14:55:40.123Z`. `DateFormatter` is documented thread-safe for
    /// formatting, and this one is immutable after creation.
    public static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// A quoted, fully escaped JSON string.
    ///
    /// `JSONEncoder` handles the escaping — quotes, control characters, lone
    /// surrogates — rather than a hand-rolled escaper, because a single missed
    /// case would emit a line the agent's `jq` cannot parse. Falls back to an
    /// empty JSON string, never to invalid JSON.
    static func quoted(_ string: String, using encoder: JSONEncoder) -> String {
        guard let data = try? encoder.encode(string),
              let out = String(data: data, encoding: .utf8) else { return "\"\"" }
        return out
    }

    public static func makeEncoder() -> JSONEncoder { JSONEncoder() }
}

public extension DevLogRecord {
    /// The record as a single JSONL line, **without** a trailing newline.
    ///
    /// Composed by hand rather than via `Encodable` for one reason: field order.
    /// `JSONEncoder` emits synthesised keys in an arbitrary order, which makes a
    /// raw `tail -f` unreadable. Here `ts`, `seq`, `kind` always lead, and
    /// `meta` keys are sorted, so lines are stable and diffable. `msg` is quoted
    /// by `JSONEncoder`, so escaping is still the standard library's problem.
    ///
    /// Returns `nil` only if the timestamp cannot be formatted. Instrumentation
    /// never propagates its own failures into the code it observes.
    func jsonLine(using encoder: JSONEncoder) -> Data? {
        let q = { DevLogEncoding.quoted($0, using: encoder) }

        var out = "{"
        out += "\"ts\":\(q(DevLogEncoding.timestampFormatter.string(from: ts)))"
        out += ",\"seq\":\(seq)"
        out += ",\"kind\":\(q(kind.rawValue))"
        out += ",\"msg\":\(q(msg))"
        out += ",\"src\":\(q(src))"
        out += ",\"fn\":\(q(fn))"
        out += ",\"session\":\(q(session))"
        out += ",\"meta\":{"
        out += meta.keys.sorted().map { "\(q($0)):\(q(meta[$0]!))" }.joined(separator: ",")
        out += "}}"

        return Data(out.utf8)
    }
}
