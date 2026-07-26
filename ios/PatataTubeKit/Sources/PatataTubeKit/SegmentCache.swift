import CryptoKit
import Foundation

enum SegmentCacheError: Error, Equatable {
    case invalidAssetPath
}

/// On-disk cache of HLS package assets (init/segments/playlists/subtitles).
/// Keyed by (videoId, versionId, packageHash) where the hash comes from the media
/// playlist bytes — a server-side repackage (e.g. audio-language change)
/// yields a new hash, so stale segments can never be served.
actor SegmentCache {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    nonisolated static func packageHash(forPlaylist data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    nonisolated func videoDir(videoId: Int) -> URL {
        root.appendingPathComponent("\(videoId)", isDirectory: true)
    }

    private func packageScopeDir(videoId: Int, versionId: Int?) -> URL {
        let videoDirectory = videoDir(videoId: videoId)
        guard let versionId else { return videoDirectory }
        return videoDirectory.appendingPathComponent("version-\(versionId)", isDirectory: true)
    }

    private func packageDir(videoId: Int, versionId: Int?, hash: String) -> URL {
        packageScopeDir(videoId: videoId, versionId: versionId)
            .appendingPathComponent(hash, isDirectory: true)
    }

    /// Resolves `asset` under the package directory, rejecting path traversal.
    private func assetURL(
        videoId: Int,
        versionId: Int?,
        hash: String,
        asset: String
    ) -> URL? {
        guard !asset.hasPrefix("/"), !asset.contains("..") else { return nil }
        return packageDir(videoId: videoId, versionId: versionId, hash: hash)
            .appendingPathComponent(asset)
    }

    func cachedData(
        videoId: Int,
        versionId: Int? = nil,
        hash: String,
        asset: String
    ) -> Data? {
        guard let url = assetURL(
            videoId: videoId,
            versionId: versionId,
            hash: hash,
            asset: asset
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    func store(
        videoId: Int,
        versionId: Int? = nil,
        hash: String,
        asset: String,
        data: Data
    ) throws {
        guard let url = assetURL(
            videoId: videoId,
            versionId: versionId,
            hash: hash,
            asset: asset
        ) else {
            throw SegmentCacheError.invalidAssetPath
        }

        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporaryURL)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    func cachedAssets(
        videoId: Int,
        versionId: Int? = nil,
        hash: String
    ) -> Set<String> {
        let directory = packageDir(videoId: videoId, versionId: versionId, hash: hash)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var assets: Set<String> = []
        let resolvedDirectoryPath = directory.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix(".")
            else { continue }
            let resolvedAssetPath = url.resolvingSymlinksInPath().path
            let relativePath = String(resolvedAssetPath.dropFirst(resolvedDirectoryPath.count + 1))
            assets.insert(relativePath)
        }
        return assets
    }

    func dropOtherPackages(
        videoId: Int,
        versionId: Int? = nil,
        keeping hash: String
    ) {
        dropOtherPackages(videoId: videoId, versionId: versionId, keeping: [hash])
    }

    func dropOtherPackages(
        videoId: Int,
        versionId: Int? = nil,
        keeping hashes: Set<String>
    ) {
        let scopeDirectory = packageScopeDir(videoId: videoId, versionId: versionId)
        let contents = (try? fileManager.contentsOfDirectory(
            at: scopeDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents
        where !hashes.contains(url.lastPathComponent)
            && (versionId != nil || !url.lastPathComponent.hasPrefix("version-"))
        {
            try? fileManager.removeItem(at: url)
        }
    }

    func removeAll(videoId: Int) {
        try? fileManager.removeItem(at: videoDir(videoId: videoId))
    }
}
