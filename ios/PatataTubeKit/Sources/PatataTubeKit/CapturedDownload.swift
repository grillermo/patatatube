import Foundation

struct CapturedDownloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL
    let totalByteCount: Int64
    let etag: String
    var capturedRanges: [DownloadByteRange]

    var cacheKey: String { versionId.map { "\(videoId):\($0)" } ?? "\(videoId)" }

    var progress: Double {
        guard totalByteCount > 0 else { return 0 }
        let covered = CapturedRanges.coveredBytes(capturedRanges)
        return min(max(Double(covered) / Double(totalByteCount), 0), 1)
    }

    var isComplete: Bool { CapturedRanges.isComplete(capturedRanges, total: totalByteCount) }

    static func make(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        totalByteCount: Int64,
        etag: String
    ) -> CapturedDownloadManifest {
        CapturedDownloadManifest(
            schemaVersion: currentSchemaVersion,
            videoId: videoId,
            versionId: versionId,
            remoteURL: remoteURL,
            totalByteCount: totalByteCount,
            etag: etag,
            capturedRanges: []
        )
    }

    mutating func capture(_ range: DownloadByteRange) {
        capturedRanges = CapturedRanges.inserting(range, into: capturedRanges)
    }
}
