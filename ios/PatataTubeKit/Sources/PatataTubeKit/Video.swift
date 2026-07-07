public struct Video: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let url: String
    public let title: String?
    public let platform: String?
    public let sourceKey: String?
    public let previewUrl: String?
    public let classification: String
    public let position: Int?
    public let status: String
    public let errorMsg: String?
    public let streamPath: String
    public let source: String?
    public let showTitle: String?
    public let season: Int?
    public let episode: Int?
    public let summary: String?
    public let showPreviewUrl: String?

    public var isLibrary: Bool { source == "library" }

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, classification: String,
                position: Int?, status: String, errorMsg: String?, streamPath: String,
                source: String? = nil, showTitle: String? = nil, season: Int? = nil,
                episode: Int? = nil, summary: String? = nil, showPreviewUrl: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.classification = classification; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
        self.source = source; self.showTitle = showTitle; self.season = season
        self.episode = episode; self.summary = summary; self.showPreviewUrl = showPreviewUrl
    }

    func withClassification(_ c: String) -> Video {
        Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: c, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl)
    }
}
