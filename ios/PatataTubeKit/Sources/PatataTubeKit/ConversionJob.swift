import Foundation

/// One unit of server-side ffmpeg work, as reported by GET /api/jobs.
/// `progress` is nil while the job is still queued -- the UI shows an
/// indeterminate spinner for those and a determinate ring once it is a number.
public struct ConversionJob: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let videoID: Int
    public let versionID: Int?
    public let kind: String
    public let progress: Double?
    public let title: String?
    public let showTitle: String?

    public init(
        id: Int, videoID: Int, versionID: Int?, kind: String,
        progress: Double?, title: String?, showTitle: String?
    ) {
        self.id = id
        self.videoID = videoID
        self.versionID = versionID
        self.kind = kind
        self.progress = progress
        self.title = title
        self.showTitle = showTitle
    }

    // JSONDecoder's .convertFromSnakeCase turns "video_id" into "videoId" and
    // "version_id" into "versionId" -- lowercase `d`, which does not match the
    // `videoID`/`versionID` property names (capital `ID`, matching the rest of
    // this codebase's convention -- see Video.groupID). Explicit keys needed
    // for just these two; the rest convert automatically.
    private enum CodingKeys: String, CodingKey {
        case id, kind, progress, title, showTitle
        case videoID = "videoId"
        case versionID = "versionId"
    }
}

public struct JobsSnapshot: Decodable, Equatable, Sendable {
    public let running: [ConversionJob]
    public let queued: [ConversionJob]
    public let queuedTotal: Int

    public init(running: [ConversionJob], queued: [ConversionJob], queuedTotal: Int) {
        self.running = running
        self.queued = queued
        self.queuedTotal = queuedTotal
    }

    public static let empty = JobsSnapshot(running: [], queued: [], queuedTotal: 0)
}

public enum ConversionState: Equatable, Sendable {
    case running(Double)
    case queued
}

/// Narrower than VideoAPI on purpose: JobsStore needs one call, and its tests
/// should not have to stub twenty unrelated methods.
public protocol JobsAPI: Sendable {
    func jobs() async throws -> JobsSnapshot
}
