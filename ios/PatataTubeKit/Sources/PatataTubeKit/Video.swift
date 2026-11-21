public struct Video: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let url: String
    public let title: String?
    public let platform: String?
    public let sourceKey: String?
    /// The YouTube channel this video came from, when the server knows it.
    /// Nil for Twitter, uploads, and YouTube downloads that predate the
    /// server recording it.
    public let channel: String?
    public let previewUrl: String?
    /// The group this video is in, or nil when it is unsorted.
    public let groupID: Int?
    public let position: Int?
    public let status: String
    public let errorMsg: String?
    public let streamPath: String
    /// Always nil from the current server; kept because the offline cache and
    /// the stream proxy still key files on it (`versionId` plumbing).
    public let chosenVersionId: Int?
    public let hlsPath: String?
    public let resumeSecs: Double
    /// Announced by the server and never played: what the red dot marks. The
    /// server decides (it is the same rule its group badge counts); the app
    /// only ever clears it, when playback starts.
    public private(set) var unwatched: Bool

    enum CodingKeys: String, CodingKey {
        case id, url, title, platform, sourceKey, channel, previewUrl, position
        case groupID = "groupId"
        case status, errorMsg, streamPath, chosenVersionId, hlsPath
        case resumeSecs
        case unwatched
    }

    private enum RawGroupCodingKeys: String, CodingKey {
        case groupID = "group_id"
    }

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, groupID: Int?,
                position: Int?, status: String, errorMsg: String?, streamPath: String,
                chosenVersionId: Int? = nil,
                hlsPath: String? = nil,
                resumeSecs: Double = 0,
                channel: String? = nil,
                unwatched: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.groupID = groupID; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
        self.chosenVersionId = chosenVersionId
        self.hlsPath = hlsPath
        self.resumeSecs = resumeSecs
        self.channel = channel
        self.unwatched = unwatched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: RawGroupCodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.url = try c.decode(String.self, forKey: .url)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.platform = try c.decodeIfPresent(String.self, forKey: .platform)
        self.sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        self.previewUrl = try c.decodeIfPresent(String.self, forKey: .previewUrl)
        self.groupID = try raw.decodeIfPresent(Int.self, forKey: .groupID)
            ?? c.decodeIfPresent(Int.self, forKey: .groupID)
        self.position = try c.decodeIfPresent(Int.self, forKey: .position)
        self.status = try c.decode(String.self, forKey: .status)
        self.errorMsg = try c.decodeIfPresent(String.self, forKey: .errorMsg)
        self.streamPath = try c.decodeIfPresent(String.self, forKey: .streamPath) ?? ""
        self.chosenVersionId = try c.decodeIfPresent(Int.self, forKey: .chosenVersionId)
        self.hlsPath = try c.decodeIfPresent(String.self, forKey: .hlsPath)
        self.resumeSecs = try c.decodeIfPresent(Double.self, forKey: .resumeSecs) ?? 0
        self.channel = try c.decodeIfPresent(String.self, forKey: .channel)
        // Absent from lists cached before the field existed.
        self.unwatched = try c.decodeIfPresent(Bool.self, forKey: .unwatched) ?? false
    }

    public func markingWatched() -> Video {
        var copy = self
        copy.unwatched = false
        return copy
    }

    func withGroupID(_ groupID: Int?) -> Video {
        Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, groupID: groupID, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              chosenVersionId: chosenVersionId, hlsPath: hlsPath,
              resumeSecs: resumeSecs, channel: channel, unwatched: unwatched)
    }
}
