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
    /// Video/version scope to its latest fetched media-playlist hash.
    private var currentHash: [PlaylistScope: String] = [:]
    /// Playlists fetched before `video.m3u8` establishes their package hash.
    private var pendingPlaylists: [PlaylistScope: [String: Data]] = [:]
    private let singleFlight = SingleFlight<Data>()
    private let probeSingleFlight = SingleFlight<DownloadProbe>()

    public private(set) var port: UInt16? {
        get { lock.withLock { _port } }
        set { lock.withLock { _port = newValue } }
    }

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
        guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: 0) else {
            port = nil
            return
        }
        let server = HTTPServer(address: address)
        await server.appendRoute(HTTPRoute("GET /\(secret)/hls/:id/:v/*")) { [weak self] request in
            await self?.handleHLS(request) ?? HTTPResponse(statusCode: .notFound)
        }
        await server.appendRoute(HTTPRoute("GET /\(secret)/mp4/:id/:v")) { [weak self] request in
            await self?.handleMP4(request) ?? HTTPResponse(statusCode: .notFound)
        }
        await server.appendRoute(HTTPRoute("GET /\(secret)/offline/:id/:v/*")) { [weak self] request in
            await self?.handleOffline(request) ?? HTTPResponse(statusCode: .notFound)
        }
        self.server = server
        serverTask = Task { try? await server.run() }
        do {
            try await server.waitUntilListening()
            if case let .ip4(_, port: listeningPort)? = await server.listeningAddress {
                port = listeningPort
            }
        } catch {
            port = nil
        }
    }

    public func stop() async {
        await server?.stop()
        serverTask?.cancel()
        serverTask = nil
        server = nil
        port = nil
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
        return URL(
            string: "http://127.0.0.1:\(port)/\(secret)/\(kind)/\(videoId)/\(versionId ?? 0)\(suffix)"
        )
    }

    // MARK: - Upstream helpers

    private struct RouteParams {
        let videoId: Int
        let versionId: Int?
        let asset: String
    }

    private struct PlaylistScope: Hashable {
        let videoId: Int
        let versionId: Int?
    }

    private func activePackageHashes(for videoId: Int) -> Set<String> {
        lock.withLock {
            Set(
                currentHash.compactMap { scope, hash in
                    scope.videoId == videoId ? hash : nil
                }
            )
        }
    }

    private func params(of request: HTTPRequest) -> RouteParams? {
        guard let idText = request.routeParameters["id"],
              let videoId = Int(idText),
              let vText = request.routeParameters["v"],
              let version = Int(vText)
        else {
            return nil
        }
        let marker = "/\(idText)/\(vText)/"
        let asset: String
        if let range = request.path.range(of: marker) {
            asset = String(request.path[range.upperBound...]).removingPercentEncoding ?? ""
        } else {
            asset = ""
        }
        return RouteParams(
            videoId: videoId,
            versionId: version == 0 ? nil : version,
            asset: asset
        )
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
            versionId: version == 0 ? nil : version,
            asset: ""
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

    private func contentType(for asset: String) -> String {
        switch (asset as NSString).pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "vtt": "text/vtt"
        case "m4s": "video/iso.segment"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }

    private func isSuccessful(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(response.statusCode)
    }

    // MARK: - HLS

    private func handleHLS(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = params(of: request),
              !params.asset.isEmpty,
              !params.asset.hasPrefix("/"),
              !params.asset.contains("..")
        else {
            return HTTPResponse(statusCode: .notFound)
        }
        let headers: HTTPHeaders = [.contentType: contentType(for: params.asset)]
        if params.asset.hasSuffix(".m3u8") {
            return await servePlaylist(params, headers: headers)
        }
        return await serveHLSAsset(params, headers: headers)
    }

    private func servePlaylist(
        _ params: RouteParams,
        headers: HTTPHeaders
    ) async -> HTTPResponse {
        let scope = PlaylistScope(
            videoId: params.videoId,
            versionId: params.versionId
        )
        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/hls/\(params.asset)",
            versionId: params.versionId
        ) else {
            return HTTPResponse(statusCode: .badGateway)
        }

        do {
            let (data, response) = try await session.data(for: upstreamRequest(url: url))
            guard isSuccessful(response) else {
                throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            var pending: [String: Data] = [:]
            let hash: String?
            if params.asset == "video.m3u8" {
                let packageHash = SegmentCache.packageHash(forPlaylist: data)
                pending = lock.withLock {
                    currentHash[scope] = packageHash
                    return pendingPlaylists.removeValue(forKey: scope) ?? [:]
                }
                await cache.segments.dropOtherPackages(
                    videoId: params.videoId,
                    keeping: activePackageHashes(for: params.videoId)
                )
                hash = packageHash
            } else {
                hash = lock.withLock {
                    if let hash = currentHash[scope] {
                        return hash
                    }
                    pendingPlaylists[scope, default: [:]][params.asset] = data
                    return nil
                }
            }
            if let hash {
                for (asset, pendingData) in pending {
                    await storePlaylist(
                        videoId: params.videoId,
                        hash: hash,
                        asset: asset,
                        data: pendingData
                    )
                }
                await storePlaylist(
                    videoId: params.videoId,
                    hash: hash,
                    asset: params.asset,
                    data: data
                )
            }
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        } catch {
            if let hash = lock.withLock({ currentHash[scope] }),
               let cached = await cache.segments.cachedData(
                   videoId: params.videoId,
                   hash: hash,
                   asset: params.asset
               ) {
                cache.touchAndEnforce(
                    entryDir: cache.segments.videoDir(videoId: params.videoId)
                )
                return HTTPResponse(statusCode: .ok, headers: headers, body: cached)
            }
            return HTTPResponse(statusCode: .badGateway)
        }
    }

    private func storePlaylist(
        videoId: Int,
        hash: String,
        asset: String,
        data: Data
    ) async {
        await storeHLSAssetWithRecovery(
            videoId: videoId,
            hash: hash,
            asset: asset,
            data: data
        )
    }

    private func storeHLSAssetWithRecovery(
        videoId: Int,
        hash: String,
        asset: String,
        data: Data
    ) async {
        let entry = cache.segments.videoDir(videoId: videoId)
        do {
            try await cache.segments.store(
                videoId: videoId,
                hash: hash,
                asset: asset,
                data: data
            )
            cache.touchAndEnforce(entryDir: entry)
        } catch {
            await cache.evictForStorageFailure(failedEntry: entry)
            do {
                try await cache.segments.store(
                    videoId: videoId,
                    hash: hash,
                    asset: asset,
                    data: data
                )
                cache.touchAndEnforce(entryDir: entry)
            } catch {
                // Playback remains pass-through after one bounded retry.
            }
        }
    }

    private func serveHLSAsset(
        _ params: RouteParams,
        headers: HTTPHeaders
    ) async -> HTTPResponse {
        let scope = PlaylistScope(
            videoId: params.videoId,
            versionId: params.versionId
        )
        var hash = lock.withLock { currentHash[scope] }
        if hash == nil {
            _ = await servePlaylist(
                RouteParams(
                    videoId: params.videoId,
                    versionId: params.versionId,
                    asset: "video.m3u8"
                ),
                headers: [:]
            )
            hash = lock.withLock { currentHash[scope] }
        }
        guard let hash else {
            return HTTPResponse(statusCode: .badGateway)
        }

        if let cached = await cache.segments.cachedData(
            videoId: params.videoId,
            hash: hash,
            asset: params.asset
        ) {
            cache.touchAndEnforce(entryDir: cache.segments.videoDir(videoId: params.videoId))
            return HTTPResponse(statusCode: .ok, headers: headers, body: cached)
        }

        guard let url = upstreamURL(
            path: "videos/\(params.videoId)/hls/\(params.asset)",
            versionId: params.versionId
        ) else {
            return HTTPResponse(statusCode: .badGateway)
        }
        do {
            let request = upstreamRequest(url: url)
            let data = try await singleFlight.run(key: url.absoluteString) { [session] in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode)
                else {
                    throw APIError.badStatus(
                        (response as? HTTPURLResponse)?.statusCode ?? 0
                    )
                }
                return data
            }
            await storeHLSAssetWithRecovery(
                videoId: params.videoId,
                hash: hash,
                asset: params.asset,
                data: data
            )
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        } catch {
            return HTTPResponse(statusCode: .badGateway)
        }
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
                    return HTTPResponse(statusCode: .rangeNotSatisfiable)
                }
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
                return await passthroughMP4(window: window, total: total, url: url)
                    ?? HTTPResponse(statusCode: .badGateway)
            }
            cache.touchAndEnforce(entryDir: cache.ranges.entryDir(key: key))
            return partialResponse(data: data, window: window, total: total)
        } catch {
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

    // MARK: - Offline

    private func handleOffline(_ request: HTTPRequest) async -> HTTPResponse {
        guard let params = params(of: request),
              !params.asset.isEmpty,
              let offlineRoot,
              !params.asset.contains(".."),
              !params.asset.hasPrefix("/")
        else {
            return HTTPResponse(statusCode: .notFound)
        }
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
