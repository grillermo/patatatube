public struct VideoVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let label: String?
    public let status: String
    public let isChosen: Bool

    public init(id: Int, label: String?, status: String, isChosen: Bool) {
        self.id = id
        self.label = label
        self.status = status
        self.isChosen = isChosen
    }
}

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
    public let chosenVersionId: Int?
    public let versions: [VideoVersion]

    enum CodingKeys: String, CodingKey {
        case id, url, title, platform, sourceKey, previewUrl, classification, position
        case status, errorMsg, streamPath, source, showTitle, season, episode, summary
        case showPreviewUrl, chosenVersionId, versions
    }

    public var isLibrary: Bool { source == "library" }

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, classification: String,
            position: Int?, status: String, errorMsg: String?, streamPath: String,
            source: String? = nil, showTitle: String? = nil, season: Int? = nil,
            episode: Int? = nil, summary: String? = nil, showPreviewUrl: String? = nil,
            chosenVersionId: Int? = nil, versions: [VideoVersion] = []) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.classification = classification; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
        self.source = source; self.showTitle = showTitle; self.season = season
        self.episode = episode; self.summary = summary; self.showPreviewUrl = showPreviewUrl
        self.chosenVersionId = chosenVersionId; self.versions = versions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.url = try c.decode(String.self, forKey: .url)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.platform = try c.decodeIfPresent(String.self, forKey: .platform)
        self.sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
        self.previewUrl = try c.decodeIfPresent(String.self, forKey: .previewUrl)
        self.classification = try c.decode(String.self, forKey: .classification)
        self.position = try c.decodeIfPresent(Int.self, forKey: .position)
        self.status = try c.decode(String.self, forKey: .status)
        self.errorMsg = try c.decodeIfPresent(String.self, forKey: .errorMsg)
        self.streamPath = try c.decode(String.self, forKey: .streamPath)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.showTitle = try c.decodeIfPresent(String.self, forKey: .showTitle)
        self.season = try c.decodeIfPresent(Int.self, forKey: .season)
        self.episode = try c.decodeIfPresent(Int.self, forKey: .episode)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.showPreviewUrl = try c.decodeIfPresent(String.self, forKey: .showPreviewUrl)
        self.chosenVersionId = try c.decodeIfPresent(Int.self, forKey: .chosenVersionId)
        self.versions = try c.decodeIfPresent([VideoVersion].self, forKey: .versions) ?? []
    }

    func withClassification(_ c: String) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
            previewUrl: previewUrl, classification: c, position: position,
            status: status, errorMsg: errorMsg, streamPath: streamPath,
            source: source, showTitle: showTitle, season: season,
            episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
            chosenVersionId: chosenVersionId, versions: versions)
    }

    func withChosenVersion(_ versionId: Int) -> Video {
        let selected = versions.first { $0.id == versionId }
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: classification, position: position,
              status: selected?.status ?? status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: versionId,
              versions: versions.map {
                  VideoVersion(id: $0.id, label: $0.label, status: $0.status, isChosen: $0.id == versionId)
              })
    }
}
