import Foundation

/// What a remote file is: its strong ETag and its size. Every byte in an entry
/// belongs to one identity; meeting a different one resets the entry.
struct MediaIdentity: Codable, Equatable, Sendable {
    let etag: String
    let totalByteCount: Int64
}

/// Everything needed to start a download again, possibly in a later process.
struct DownloadJobParameters: Codable, Equatable, Sendable {
    let remoteURL: URL
    let streamCount: Int
    let previewURL: URL?
    let showPosterKey: String?
    let showPosterURL: URL?
}

/// A pinned entry is a download: never evicted, and restarted by
/// `resumeInterrupted` unless paused.
struct PinState: Codable, Equatable, Sendable {
    let job: DownloadJobParameters
    var paused: Bool
}

/// `entry.json`. `identity` is nil only for an entry pinned before its first
/// probe (a fresh download, or a 2.8 paused download carried over by
/// `LegacyCacheMigration`); such an entry has no bytes and no `data.bin` yet.
struct MediaEntryManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = MediaEntryManifest.currentSchemaVersion
    let key: String
    var identity: MediaIdentity?
    var committed: ByteRangeSet
    var pin: PinState?
    var lastAccess: Date

    var isComplete: Bool {
        guard let identity else { return false }
        return committed.contains(DownloadByteRange(start: 0, end: identity.totalByteCount - 1))
    }

    var progress: Double {
        guard let total = identity?.totalByteCount, total > 0 else { return 0 }
        return min(Double(committed.totalBytes) / Double(total), 1)
    }

    func validated() throws -> MediaEntryManifest {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MediaStoreError.corruptManifest
        }
        if let identity {
            guard identity.totalByteCount > 0,
                  committed.runs.allSatisfy({ $0.start >= 0 && $0.end < identity.totalByteCount })
            else { throw MediaStoreError.corruptManifest }
        } else {
            guard committed.runs.isEmpty else { throw MediaStoreError.corruptManifest }
        }
        return self
    }
}

enum MediaStoreError: Error, Equatable {
    case corruptManifest
    /// A write, a sync or a rename failed even after evicting to make room.
    case storageFull
    /// A fetcher tried to commit bytes outside its claim. A programming error.
    case commitOutsideClaim
    /// Every byte arrived but renaming `data.bin` to the mp4 failed. The entry
    /// stays complete; the next open or claim retries the rename.
    case promotionFailed
}
