import Foundation

/// 2.8 → 2.9: the stream cache, segmented part files and `.resume` files
/// are gone; paused downloads become paused, pinned store entries that
/// start from zero bytes once. Idempotent and cheap, so it runs on every
/// launch from `CacheManager.init`, before `MediaStore` touches the disk.
enum LegacyCacheMigration {
    /// Returns the keys turned into paused entries.
    @discardableResult
    static func run(videosRoot: URL, legacyStreamRoot: URL?, now: Date) -> [String] {
        let fm = FileManager.default
        if let legacyStreamRoot, fm.fileExists(atPath: legacyStreamRoot.path) {
            try? fm.removeItem(at: legacyStreamRoot)
            DevLog.event(.cache, "legacy stream cache removed", [:])
        }
        try? fm.removeItem(at: videosRoot.appendingPathComponent(".downloads", isDirectory: true))
        let contents = (try? fm.contentsOfDirectory(atPath: videosRoot.path)) ?? []
        for name in contents where name.hasSuffix(".resume") {
            try? fm.removeItem(at: videosRoot.appendingPathComponent(name))
        }

        // Loading the store drops 2.8 HLS entries and records their ids for
        // CacheManager.removeLegacyHLSPackages, exactly as before.
        var legacy = PausedDownloadStore(root: videosRoot)
        guard !legacy.entries.isEmpty else { return [] }
        let storeRoot = MediaStore.storeRoot(videosRoot: videosRoot)
        var converted: [String] = []
        for paused in legacy.entries {
            let key = paused.id
            let finished = videosRoot.appendingPathComponent(MediaKey.finishedFilename(key))
            guard !fm.fileExists(atPath: finished.path),
                  MediaStore.readManifest(storeRoot: storeRoot, key: key) == nil
            else {
                legacy.remove(key)  // nothing left to convert for this one
                continue
            }
            let manifest = MediaEntryManifest(
                key: key,
                identity: nil,
                committed: ByteRangeSet(),
                pin: PinState(
                    job: DownloadJobParameters(
                        remoteURL: paused.remoteURL,
                        streamCount: paused.streamCount,
                        previewURL: paused.previewURL,
                        showPosterKey: paused.showPosterKey,
                        showPosterURL: paused.showPosterURL
                    ),
                    paused: true
                ),
                lastAccess: now
            )
            // A failed write keeps its legacy entry, so the next launch retries.
            guard (try? MediaStore.writeManifest(manifest, storeRoot: storeRoot)) != nil else { continue }
            legacy.remove(key)
            converted.append(key)
        }
        DevLog.event(.download, "legacy paused downloads carried over", [
            "keys": converted.joined(separator: ","),
        ])
        return converted
    }
}
