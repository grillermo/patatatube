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
    private let lock = NSLock()
    private var _port: UInt16?
    private var serverTask: Task<Void, Never>?
    /// Not private so tests can kill the listener the way iOS does — out from
    /// under the proxy, without going through `stop()`.
    var server: HTTPServer?
    /// Loopback liveness probe. Separate from `session`, which callers replace
    /// with a mock protocol for the upstream side.
    private let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()
    private let probeSingleFlight = SingleFlight<DownloadProbe>()

    public private(set) var port: UInt16? {
        get { lock.withLock { _port } }
        set { lock.withLock { _port = newValue } }
    }

    public init(
        cache: StreamCache,
        credentials: CredentialStore,
        session: URLSession = .shared
    ) {
        self.cache = cache
        self.credentials = credentials
        self.session = session
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

    private func upstreamRequest(url: URL, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = credentials.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private func isSuccessful(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }

    // MARK: - MP4

    private func handleMP4(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = mp4Params(of: request) else {
            return HTTPResponse(statusCode: .notFound)
        }
        let key = params.versionId.map { "\(params.videoId):\($0)" } ?? "\(params.videoId)"
        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/stream",
            versionId: params.versionId
        ) else {
            return HTTPResponse(statusCode: .badGateway)
        }

        var manifest = await cache.ranges.manifest(key: key)
        if manifest == nil {
            let probe: DownloadProbe
            do {
                probe = try await probeSingleFlight.run(key: key) { [self] in
                    let (body, response) = try await session.data(
                        for: upstreamRequest(url: url, range: "bytes=0-0")
                    )
                    guard let response = response as? HTTPURLResponse else {
                        throw SegmentedDownloadError.invalidProbe
                    }
                    return try SegmentedDownloadStore.validateProbe(
                        response,
                        bodyCount: body.count
                    )
                }
            } catch {
                DevLog.event(.proxy, "MP4 probe failed -> 502", [
                    "video_id": "\(params.videoId)", "err": "\(error)",
                ])
                return HTTPResponse(statusCode: .badGateway)
            }
            do {
                try await prepareMP4WithRecovery(
                    key: key,
                    etag: probe.etag,
                    totalByteCount: probe.totalByteCount
                )
            } catch {
                guard let window = boundedWindow(
                    rangeHeader: request.headers[.range],
                    total: probe.totalByteCount
                ) else {
                    DevLog.event(.proxy, "MP4 range not satisfiable", [
                        "video_id": "\(params.videoId)",
                        "range": request.headers[.range] ?? "-",
                        "total": "\(probe.totalByteCount)",
                    ])
                    return HTTPResponse(statusCode: .rangeNotSatisfiable)
                }
                DevLog.event(.proxy, "MP4 prepare failed, passing through", [
                    "video_id": "\(params.videoId)", "err": "\(error)",
                ])
                return await passthroughMP4(
                    window: window,
                    total: probe.totalByteCount,
                    url: url
                ) ?? HTTPResponse(statusCode: .badGateway)
            }
            manifest = await cache.ranges.manifest(key: key)
        }
        guard var manifest else {
            return HTTPResponse(statusCode: .badGateway)
        }

        var total = manifest.totalByteCount
        let rangeHeader = request.headers[.range]
        guard var window = boundedWindow(
            rangeHeader: rangeHeader,
            total: total
        ) else {
            return HTTPResponse(statusCode: .rangeNotSatisfiable)
        }

        var missing = manifest.ranges.missingRanges(in: window)
        while !missing.isEmpty {
            var entityChanged = false
            for hole in missing {
                do {
                    let (body, response) = try await session.data(
                        for: upstreamRequest(url: url, range: hole.headerValue)
                    )
                    guard let response = response as? HTTPURLResponse,
                          response.statusCode == 206
                    else {
                        throw APIError.badStatus(
                            (response as? HTTPURLResponse)?.statusCode ?? 0
                        )
                    }
                    guard let responseETag = response.value(forHTTPHeaderField: "ETag") else {
                        throw SegmentedDownloadError.changedEntity
                    }
                    if responseETag != manifest.etag {
                        guard let contentRange = response.value(
                            forHTTPHeaderField: "Content-Range"
                        ).flatMap(parseContentRange),
                            contentRange.range.start == hole.start,
                            contentRange.range.end
                                == hole.start + Int64(body.count) - 1,
                            let replacementWindow = boundedWindow(
                                rangeHeader: rangeHeader,
                                total: contentRange.total
                            )
                        else {
                            throw SegmentedDownloadError.changedEntity
                        }
                        // The file changed underneath an in-flight playback —
                        // the server re-encoded or re-promoted it. Everything
                        // cached for this key is now wrong.
                        DevLog.event(.proxy, "MP4 entity changed mid-stream", [
                            "video_id": "\(params.videoId)",
                            "old_etag": manifest.etag,
                            "new_etag": responseETag,
                            "old_total": "\(manifest.totalByteCount)",
                            "new_total": "\(contentRange.total)",
                        ])
                        total = contentRange.total
                        window = replacementWindow
                        try await prepareMP4WithRecovery(
                            key: key,
                            etag: responseETag,
                            totalByteCount: total
                        )
                        guard let refreshed = await cache.ranges.manifest(key: key) else {
                            throw SegmentedDownloadError.changedEntity
                        }
                        manifest = refreshed
                        missing = [window]
                        entityChanged = true
                        break
                    }
                    let committed = try await writeMP4WithRecovery(
                        key: key,
                        offset: hole.start,
                        data: body,
                        manifest: manifest
                    )
                    guard committed else {
                        guard
                            let refreshed = await cache.ranges.manifest(key: key),
                            let refreshedWindow = boundedWindow(
                                rangeHeader: rangeHeader,
                                total: refreshed.totalByteCount
                            )
                        else {
                            throw SegmentedDownloadError.changedEntity
                        }
                        manifest = refreshed
                        total = refreshed.totalByteCount
                        window = refreshedWindow
                        missing = refreshed.ranges.missingRanges(in: refreshedWindow)
                        entityChanged = true
                        break
                    }
                    cache.touchAndEnforce(entryDir: cache.ranges.entryDir(key: key))
                } catch {
                    DevLog.event(.proxy, "MP4 hole fetch failed, passing through", [
                        "video_id": "\(params.videoId)",
                        "hole": "\(hole.start)-\(hole.end)",
                        "err": "\(error)",
                    ])
                    return await passthroughMP4(window: window, total: total, url: url)
                        ?? HTTPResponse(statusCode: .badGateway)
                }
            }
            if !entityChanged {
                missing = []
            }
        }

        do {
            guard let data = try await cache.ranges.read(key: key, range: window) else {
                // The bytes were there a moment ago (the holes were just
                // filled) and now are not — an eviction between write and read
                // is the shape to look for here.
                DevLog.event(.proxy, "MP4 cache read empty, passing through", [
                    "video_id": "\(params.videoId)",
                    "window": "\(window.start)-\(window.end)",
                ])
                return await passthroughMP4(window: window, total: total, url: url)
                    ?? HTTPResponse(statusCode: .badGateway)
            }
            cache.touchAndEnforce(entryDir: cache.ranges.entryDir(key: key))
            return partialResponse(data: data, window: window, total: total)
        } catch {
            DevLog.event(.proxy, "MP4 cache read failed, passing through", [
                "video_id": "\(params.videoId)",
                "window": "\(window.start)-\(window.end)",
                "err": "\(error)",
            ])
            return await passthroughMP4(window: window, total: total, url: url)
                ?? HTTPResponse(statusCode: .badGateway)
        }
    }

    private func prepareMP4WithRecovery(
        key: String,
        etag: String,
        totalByteCount: Int64
    ) async throws {
        do {
            try await cache.ranges.prepare(
                key: key,
                etag: etag,
                totalByteCount: totalByteCount
            )
        } catch {
            let entry = cache.ranges.entryDir(key: key)
            DevLog.event(.cache, "MP4 prepare failed, evicting and retrying", [
                "key": key, "err": "\(error)",
            ])
            await cache.evictForStorageFailure(failedEntry: entry)
            _ = try await cache.ranges.prepareForWriteRetry(
                key: key,
                expectedETag: etag,
                expectedTotalByteCount: totalByteCount
            )
        }
    }

    private func writeMP4WithRecovery(
        key: String,
        offset: Int64,
        data: Data,
        manifest: RangeStoreManifest
    ) async throws -> Bool {
        do {
            return try await cache.ranges.write(
                key: key,
                at: offset,
                data: data,
                expectedETag: manifest.etag,
                expectedTotalByteCount: manifest.totalByteCount
            )
        } catch {
            let entry = cache.ranges.entryDir(key: key)
            DevLog.event(.cache, "MP4 write failed, evicting and retrying", [
                "key": key, "offset": "\(offset)", "bytes": "\(data.count)",
                "err": "\(error)",
            ])
            await cache.evictForStorageFailure(failedEntry: entry)
            guard try await cache.ranges.prepareForWriteRetry(
                key: key,
                expectedETag: manifest.etag,
                expectedTotalByteCount: manifest.totalByteCount
            ) else {
                return false
            }
            return try await cache.ranges.write(
                key: key,
                at: offset,
                data: data,
                expectedETag: manifest.etag,
                expectedTotalByteCount: manifest.totalByteCount
            )
        }
    }

    private func passthroughMP4(
        window: DownloadByteRange,
        total: Int64,
        url: URL
    ) async -> HTTPResponse? {
        guard let (data, response) = try? await session.data(
            for: upstreamRequest(url: url, range: window.headerValue)
        ), (response as? HTTPURLResponse)?.statusCode == 206 else {
            return nil
        }
        return partialResponse(data: data, window: window, total: total)
    }

    private func partialResponse(
        data: Data,
        window: DownloadByteRange,
        total: Int64
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: .partialContent,
            headers: [
                .contentType: "video/mp4",
                .contentRange: "bytes \(window.start)-\(window.end)/\(total)",
                .acceptRanges: "bytes",
            ],
            body: data
        )
    }

    private func parseRange(_ header: String?, total: Int64) -> DownloadByteRange? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 {
            return DownloadByteRange(start: max(0, total - suffix), end: total - 1)
        }
        guard let start = Int64(parts[0]) else { return nil }
        let end = Int64(parts[1]) ?? (total - 1)
        guard end >= start else { return nil }
        return DownloadByteRange(start: start, end: min(end, total - 1))
    }

    private struct ParsedContentRange {
        let range: DownloadByteRange
        let total: Int64
    }

    private func parseContentRange(_ value: String) -> ParsedContentRange? {
        guard value.hasPrefix("bytes "),
              let slash = value.firstIndex(of: "/"),
              let total = Int64(value[value.index(after: slash)...]),
              total > 0
        else {
            return nil
        }
        let interval = value[value.index(value.startIndex, offsetBy: 6)..<slash]
        let bounds = interval.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total
        else {
            return nil
        }
        return ParsedContentRange(
            range: DownloadByteRange(start: start, end: end),
            total: total
        )
    }

    private func boundedWindow(
        rangeHeader: String?,
        total: Int64
    ) -> DownloadByteRange? {
        let requested = parseRange(rangeHeader, total: total)
            ?? DownloadByteRange(start: 0, end: total - 1)
        guard requested.start >= 0, requested.start < total else { return nil }
        return DownloadByteRange(
            start: requested.start,
            end: min(
                requested.end,
                min(requested.start + Self.mp4Window - 1, total - 1)
            )
        )
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
