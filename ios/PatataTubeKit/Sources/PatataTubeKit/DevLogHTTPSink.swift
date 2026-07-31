import Foundation

/// Posts records to the backend's `POST /api/devlog`, which appends them to the
/// same `log/ios.jsonl` a Simulator run writes directly.
///
/// This is the sink that matters: the build that misbehaves is the Release
/// `.ipa` on a real iPad, where there is no host filesystem to write to.
///
/// Three deliberate restraints, all for the same reason — the failures being
/// investigated are network- and timing-shaped, so the instrument must not
/// perturb the network or the timing it is measuring:
///
/// 1. Its own ephemeral `URLSession`, never `CacheManager`'s download session,
///    so log traffic can't consume the download concurrency gate.
/// 2. At most one retry per batch. A retry storm during a network-caused
///    playback failure would poison the very evidence being collected.
/// 3. Bounded backlog. If the server is unreachable, old batches are dropped
///    rather than accumulating.
public final class DevLogHTTPSink: DevLogSink, @unchecked Sendable {
    /// Batches held while the server is unreachable. Past this the oldest go.
    public static let maxBacklogBatches = 32
    /// Must not exceed the server's `devlog.MAX_RECORDS_PER_REQUEST`, which
    /// answers 413 rather than buffering an oversize batch.
    public static let maxRecordsPerRequest = 512

    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let sessionID: String

    private let lock = NSLock()
    private var backlog: [[DevLogRecord]] = []
    private var inFlight = false

    /// - Parameters:
    ///   - baseURL: the backend root, e.g. `https://patatatube.example`.
    ///   - token: `UPLOAD_TOKEN`, sent as a bearer token.
    ///   - sessionID: `DevLog.session`, echoed in the payload.
    ///   - configuration: overridable for tests; defaults to `defaultConfiguration()`.
    public init(
        baseURL: URL,
        token: String,
        sessionID: String,
        configuration: URLSessionConfiguration = DevLogHTTPSink.defaultConfiguration()
    ) {
        self.endpoint = baseURL.appendingPathComponent("api/devlog")
        self.token = token
        self.sessionID = sessionID
        self.session = URLSession(configuration: configuration)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false      // drop it, don't queue it
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    public func write(_ records: [DevLogRecord]) {
        guard !records.isEmpty else { return }

        lock.lock()
        for start in stride(from: 0, to: records.count, by: Self.maxRecordsPerRequest) {
            let end = min(start + Self.maxRecordsPerRequest, records.count)
            backlog.append(Array(records[start..<end]))
        }
        if backlog.count > Self.maxBacklogBatches {
            backlog.removeFirst(backlog.count - Self.maxBacklogBatches)
        }
        let shouldStart = !inFlight
        if shouldStart { inFlight = true }
        lock.unlock()

        if shouldStart { sendNext(retrying: false) }
    }

    private func sendNext(retrying: Bool) {
        lock.lock()
        guard let batch = backlog.first else {
            inFlight = false
            lock.unlock()
            return
        }
        lock.unlock()

        guard let body = payload(for: batch) else {
            dropHead()
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if error == nil, (200..<300).contains(status) {
                self.dropHead()
                return
            }
            // 4xx means the server will never accept this batch (bad token,
            // too large). Retrying it would block every batch behind it.
            if (400..<500).contains(status) || retrying {
                self.dropHead()
                return
            }
            self.sendNext(retrying: true)
        }.resume()
    }

    var backlogCountForTesting: Int {
        lock.withLock { backlog.count }
    }

    private func dropHead() {
        lock.lock()
        if !backlog.isEmpty { backlog.removeFirst() }
        let more = !backlog.isEmpty
        if !more { inFlight = false }
        lock.unlock()

        if more { sendNext(retrying: false) }
    }

    private func payload(for records: [DevLogRecord]) -> Data? {
        let encoder = DevLogEncoding.makeEncoder()
        let lines = records.compactMap { $0.jsonLine(using: encoder) }
        guard !lines.isEmpty else { return nil }

        // Each record is already a JSON object; splice them into an array rather
        // than re-encoding through a second model.
        var body = Data("{\"session\":".utf8)
        body.append(Data(DevLogEncoding.quoted(sessionID, using: encoder).utf8))
        body.append(Data(",\"records\":[".utf8))
        for (index, line) in lines.enumerated() {
            if index > 0 { body.append(Data(",".utf8)) }
            body.append(line)
        }
        body.append(Data("]}".utf8))
        return body
    }
}
