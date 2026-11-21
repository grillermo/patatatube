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


    public func start() async {
        DevLog.event(.proxy, "proxy start requested")
        guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: 0) else {
            // Silent in production: `port` stays nil, every URL builder returns
            // nil, and playback quietly falls back to the network — including
            // for videos already on disk.
            DevLog.event(.proxy, "proxy bind failed — all proxied URLs will be nil")
            port = nil
            return
        }
        let server = HTTPServer(address: address)
        await server.appendRoute(HTTPRoute("GET /\(secret)/mp4/:id/:v")) { [weak self] request in
            await self?.traced("mp4", request) { await self?.handleMP4(request) }
                ?? HTTPResponse(statusCode: .notFound)
        }
        // Untraced: `ensureRunning` hits this before every play, and those
        // records would drown the ones that describe actual playback.
        await server.appendRoute(HTTPRoute("GET /\(secret)/health")) { _ in
            HTTPResponse(statusCode: .ok)
        }
        self.server = server
        serverTask = Task { [weak self] in
            do {
                try await server.run()
            } catch {
                DevLog.event(.proxy, "proxy run failed", ["err": "\(error)"])
            }
            // `run()` returning means the listener is gone. Clearing `port` is
            // what turns a silently dead proxy into a nil URL — which the URL
            // builders already log — instead of a connection refused 12s later.
            self?.serverDidExit(server)
        }
        do {
            try await server.waitUntilListening()
            if case let .ip4(_, port: listeningPort)? = await server.listeningAddress {
                port = listeningPort
            }
        } catch {
            DevLog.event(.proxy, "proxy listen failed — all proxied URLs will be nil", [
                "err": "\(error)",
            ])
            port = nil
        }
        DevLog.event(.proxy, "proxy started", ["port": port.map(String.init) ?? "nil"])
    }

    /// Rebinds the proxy when it is no longer serving. Cheap and idempotent, so
    /// callers can put it in front of every playback.
    ///
    /// The app is suspended and resumed far more often than it is launched, and
    /// iOS reclaims the listening socket while it is away. Without this the
    /// stale `port` survives the socket, every proxied URL keeps pointing at a
    /// dead address, and videos that are fully on disk fail to play until the
    /// app is relaunched.
    public func ensureRunning() async {
        if await isServing() { return }
        DevLog.event(.proxy, "proxy not serving — restarting", [
            "port": port.map(String.init) ?? "nil",
        ])
        await stop()
        await start()
    }

    /// One loopback round-trip. A non-nil `port` proves only that we bound one
    /// once; the socket can die without `run()` ever returning, so liveness has
    /// to be asked of the socket itself.
    private func isServing() async -> Bool {
        guard let port,
              let url = URL(string: "http://127.0.0.1:\(port)/\(secret)/health")
        else { return false }
        guard let (_, response) = try? await probeSession.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Only the server that is still current may clear the port — a restart may
    /// already have bound a new one by the time the old `run()` unwinds.
    private func serverDidExit(_ exited: HTTPServer) {
        guard server === exited else { return }
        port = nil
        DevLog.event(.proxy, "proxy listener exited — proxied URLs now nil")
    }

    public func stop() async {
        // A proxy that stopped while a player still holds one of its URLs looks
        // exactly like a random playback failure, so both edges are recorded.
        DevLog.event(.proxy, "proxy stopping", ["port": port.map(String.init) ?? "nil"])
        await server?.stop()
        serverTask?.cancel()
        serverTask = nil
        server = nil
        port = nil
    }

    /// Records one proxy request: what AVPlayer asked for, what it got back, and
    /// how long it took. AVPlayer's own error log only names the URI, so without
    /// this there is no way to tell a proxy fault from a backend fault.
    private func traced(
        _ route: String,
        _ request: HTTPRequest,
        _ handler: () async -> HTTPResponse?
    ) async -> HTTPResponse? {
        guard DevLog.enabled else { return await handler() }

        let started = Date()
        let response = await handler()
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        var meta: [String: String] = [
            "route": route,
            "path": request.path,
            "status": response.map { "\($0.statusCode.code)" } ?? "nil",
            "ms": "\(ms)",
        ]
        if let range = request.headers[.range] { meta["range"] = range }
        DevLog.event(.proxy, "\(route) \(response.map { "\($0.statusCode.code)" } ?? "nil")", meta)
        return response
    }

    // MARK: - Public URL builders

    public func mp4URL(videoId: Int, versionId: Int?) -> URL? {
        localURL(kind: "mp4", videoId: videoId, versionId: versionId, suffix: "")
    }

    private func localURL(kind: String, videoId: Int, versionId: Int?, suffix: String) -> URL? {
        guard let port else {
            // Every proxied URL dies
            // with the proxy. This is the moment a downloaded video loses its
            // local path, so it must not be silent.
            DevLog.event(.proxy, "proxied URL unavailable — proxy not listening", [
                "kind": kind, "video_id": "\(videoId)",
                "version_id": versionId.map(String.init) ?? "-",
            ])
            return nil
        }
        return URL(
            string: "http://127.0.0.1:\(port)/\(secret)/\(kind)/\(videoId)/\(versionId ?? 0)\(suffix)"
        )
    }

    // MARK: - Upstream helpers

    private struct RouteParams {
        let videoId: Int
        let versionId: Int?
    }

    private func mp4Params(of request: HTTPRequest) -> RouteParams? {
        guard let idText = request.routeParameters["id"],
              let videoId = Int(idText),
              let vText = request.routeParameters["v"],
              let version = Int(vText)
        else {
            return nil
        }
        return RouteParams(
            videoId: videoId,
            versionId: version == 0 ? nil : version
        )
    }

    private func upstreamURL(path: String, versionId: Int?) -> URL? {
        guard let base = credentials.baseURL,
              var components = URLComponents(
                  url: base.appendingPathComponent(path),
                  resolvingAgainstBaseURL: false
              )
        else {
            return nil
        }
        if let versionId {
            components.queryItems = (components.queryItems ?? [])
                + [URLQueryItem(name: "version_id", value: "\(versionId)")]
        }
        return components.url
    }
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


/// Deduplicates concurrent identical upstream fetches.
actor SingleFlight<Value: Sendable> {
    private var inFlight: [String: Task<Value, Error>] = [:]

    func run(
        key: String,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
