import Foundation

extension CacheManager {
    /// Downloads a complete HLS package for offline playback, reusing
    /// streamed segments and promoting only a complete package.
    public func downloadHLS(
        id: Int,
        versionId: Int? = nil,
        masterURL: URL,
        preview: URL? = nil,
        showPosterKey: String? = nil,
        showPoster: URL? = nil,
        bearerToken: String?
    ) async throws {
        let key = cacheKey(videoId: id, versionId: versionId)
        await concurrencyGate.acquire()
        defer { concurrencyGate.release() }

        guard beginExternalActivity(
            key: key,
            videoId: id,
            versionId: versionId,
            totalUnits: 10_000
        ) else {
            throw CancellationError()
        }

        let operation = Task { [self] in
            var finished = false
            defer {
                if !finished {
                    endExternalActivity(key: key)
                }
            }

            let temporaryDirectory = videosRoot
                .appendingPathComponent(".hls-tmp", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }

        func write(_ data: Data, asset: String) throws {
            let asset = try validatedHLSAssetPath(asset)
            let url = temporaryDirectory
                .appendingPathComponent(asset)
                .standardizedFileURL
            let stagingPath = temporaryDirectory.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(stagingPath) else {
                throw SegmentCacheError.invalidAssetPath
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        let masterData = try await fetchHLSAsset(
            masterURL,
            bearerToken: bearerToken
        )
        try throwIfExternalActivityCancelled(key: key)
        try write(masterData, asset: "master.m3u8")
        let masterText = String(decoding: masterData, as: UTF8.self)

        var assets: [String] = []
        var packageHash: String?
        let playlists = try HLSManifestParser.referencedPlaylists(
            inMasterPlaylist: masterText
        ).map(validatedHLSAssetPath)
        for playlist in playlists {
            let data = try await fetchHLSAsset(
                try hlsAssetURL(playlist, relativeTo: masterURL),
                bearerToken: bearerToken
            )
            try throwIfExternalActivityCancelled(key: key)
            try write(data, asset: playlist)
            if playlist == "video.m3u8" {
                packageHash = SegmentCache.packageHash(forPlaylist: data)
            }

            let text = String(decoding: data, as: UTF8.self)
            let playlistDirectory =
                (playlist as NSString).deletingLastPathComponent
            let mediaAssets = try HLSManifestParser.mediaAssets(
                inMediaPlaylist: text
            ).map(validatedHLSAssetPath)
            for mediaAsset in mediaAssets {
                let relative = playlistDirectory.isEmpty
                    ? mediaAsset
                    : "\(playlistDirectory)/\(mediaAsset)"
                let validatedRelative = try validatedHLSAssetPath(relative)
                if !assets.contains(validatedRelative) {
                    assets.append(validatedRelative)
                }
            }
        }

        let total = max(assets.count, 1)
        let segmentCache = streamSegmentCache
        let reusablePackageHash = packageHash
        try await withThrowingTaskGroup(
            of: (String, Data).self
        ) { group in
            var nextIndex = 0

            func add(_ asset: String) {
                group.addTask { [segmentCache] in
                    if let reusablePackageHash,
                       let cached = await segmentCache?.cachedData(
                           videoId: id,
                           versionId: versionId,
                           hash: reusablePackageHash,
                           asset: asset
                       )
                    {
                        try self.throwIfExternalActivityCancelled(key: key)
                        return (asset, cached)
                    }
                    let data = try await self.fetchHLSAsset(
                        try self.hlsAssetURL(asset, relativeTo: masterURL),
                        bearerToken: bearerToken
                    )
                    try self.throwIfExternalActivityCancelled(key: key)
                    return (asset, data)
                }
            }

            while nextIndex < min(3, assets.count) {
                add(assets[nextIndex])
                nextIndex += 1
            }

            var completed = 0
            while let (asset, data) = try await group.next() {
                try write(data, asset: asset)
                completed += 1
                updateExternalActivity(
                    key: key,
                    completedUnits: Int64(completed * 10_000 / total)
                )
                if nextIndex < assets.count {
                    add(assets[nextIndex])
                    nextIndex += 1
                }
            }
        }

        let destination = offlineHLSDir(
            for: id,
            versionId: versionId
        )
        try Task.checkCancellation()
        await waitBeforeExternalPromotion()
        try promoteExternalActivity(key: key) {
            try replaceOfflinePackage(
                at: destination,
                with: temporaryDirectory
            )
        }
            finished = true
        }
        registerExternalTask(key: key, task: operation)
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                self.cancelExternalActivity(key: key)
            }
        } catch {
            if operation.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        // Best-effort: missing artwork must not fail the cached HLS package.
        if let preview {
            try? await cachePreview(id: id, from: preview, bearerToken: bearerToken)
        }
        if let showPosterKey, let showPoster,
           cachedShowPosterURL(for: showPosterKey) == nil
        {
            try? await cacheShowPoster(
                key: showPosterKey,
                from: showPoster,
                bearerToken: bearerToken
            )
        }
    }

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

    private func hlsAssetURL(
        _ asset: String,
        relativeTo masterURL: URL
    ) throws -> URL {
        let asset = try validatedHLSAssetPath(asset)
        var components = URLComponents(
            url: masterURL,
            resolvingAgainstBaseURL: false
        )!
        let queryItems = components.queryItems
        components.queryItems = nil
        let base = components.url!.deletingLastPathComponent()
        let resolvedURL = base.appendingPathComponent(asset)
        let basePath = base.standardized.path + "/"
        guard resolvedURL.standardized.path.hasPrefix(basePath) else {
            throw SegmentCacheError.invalidAssetPath
        }
        var resolved = URLComponents(
            url: resolvedURL,
            resolvingAgainstBaseURL: false
        )!
        resolved.queryItems = queryItems
        return resolved.url!
    }

    private func validatedHLSAssetPath(_ asset: String) throws -> String {
        guard
            !asset.isEmpty,
            !asset.hasPrefix("/"),
            !asset.hasPrefix("~"),
            !asset.contains("\\"),
            let decoded = asset.removingPercentEncoding,
            decoded == asset
        else {
            throw SegmentCacheError.invalidAssetPath
        }

        let components = asset.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SegmentCacheError.invalidAssetPath
        }
        guard
            let urlComponents = URLComponents(string: asset),
            urlComponents.scheme == nil,
            urlComponents.host == nil,
            urlComponents.query == nil,
            urlComponents.fragment == nil
        else {
            throw SegmentCacheError.invalidAssetPath
        }
        return asset
    }

    private func replaceOfflinePackage(
        at destination: URL,
        with temporaryDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: temporaryDirectory, to: destination)
            return
        }

        let backupName = ".\(destination.lastPathComponent).backup-\(UUID().uuidString)"
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(backupName, isDirectory: true)
        do {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporaryDirectory,
                backupItemName: backupName
            )
            try? fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path)
            {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }
}
