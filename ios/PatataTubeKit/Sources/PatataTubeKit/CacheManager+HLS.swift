import Foundation

extension CacheManager {
    /// Downloads a complete HLS package for offline playback, reusing
    /// streamed segments and promoting only a complete package.
    public func downloadHLS(
        id: Int,
        versionId: Int? = nil,
        masterURL: URL,
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
            let url = temporaryDirectory.appendingPathComponent(asset)
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
        for playlist in HLSManifestParser.referencedPlaylists(
            inMasterPlaylist: masterText
        ) {
            let data = try await fetchHLSAsset(
                hlsAssetURL(playlist, relativeTo: masterURL),
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
            for mediaAsset in HLSManifestParser.mediaAssets(
                inMediaPlaylist: text
            ) {
                let relative = playlistDirectory.isEmpty
                    ? mediaAsset
                    : "\(playlistDirectory)/\(mediaAsset)"
                if !assets.contains(relative) {
                    assets.append(relative)
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
                           hash: reusablePackageHash,
                           asset: asset
                       )
                    {
                        try self.throwIfExternalActivityCancelled(key: key)
                        return (asset, cached)
                    }
                    let data = try await self.fetchHLSAsset(
                        self.hlsAssetURL(asset, relativeTo: masterURL),
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
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(
                at: temporaryDirectory,
                to: destination
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
    }

    private func fetchHLSAsset(
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

    private func hlsAssetURL(
        _ asset: String,
        relativeTo masterURL: URL
    ) -> URL {
        var components = URLComponents(
            url: masterURL,
            resolvingAgainstBaseURL: false
        )!
        let queryItems = components.queryItems
        components.queryItems = nil
        let base = components.url!.deletingLastPathComponent()
        var resolved = URLComponents(
            url: base.appendingPathComponent(asset),
            resolvingAgainstBaseURL: false
        )!
        resolved.queryItems = queryItems
        return resolved.url!
    }
}
