public struct AudioTrack: Codable, Equatable, Hashable, Sendable {
    public let lang: String
    public let title: String
    public let available: Bool

    public init(lang: String, title: String, available: Bool) {
        self.lang = lang; self.title = title; self.available = available
    }
}

public struct VideoVersion: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let label: String?
    public let status: String
    public let isChosen: Bool
    public let audioTracks: [AudioTrack]

    public init(id: Int, label: String?, status: String, isChosen: Bool,
                audioTracks: [AudioTrack] = []) {
        self.id = id
        self.label = label
        self.status = status
        self.isChosen = isChosen
        self.audioTracks = audioTracks
    }

    enum CodingKeys: String, CodingKey { case id, label, status, isChosen, audioTracks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.status = try c.decode(String.self, forKey: .status)
        self.isChosen = try c.decode(Bool.self, forKey: .isChosen)
        self.audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? []
    }
}

public struct SubtitleTrack: Codable, Equatable, Hashable, Sendable {
    public let language: String
    public let name: String
    public let `default`: Bool
    public let forced: Bool

    public init(language: String, name: String, default: Bool, forced: Bool) {
        self.language = language
        self.name = name
        self.`default` = `default`
        self.forced = forced
    }
}

public struct Video: Codable, Identifiable, Equatable, Hashable, Sendable {
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
    public let hlsPath: String?
    public let subtitleTracks: [SubtitleTrack]
    public let sourceFilename: String?
    public let audioLang: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, platform, sourceKey, previewUrl, classification, position
        case status, errorMsg, streamPath, source, showTitle, season, episode, summary
        case showPreviewUrl, chosenVersionId, versions, hlsPath, subtitleTracks
        case sourceFilename
        case audioLang
    }

    public var isLibrary: Bool { source == "library" }

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, classification: String,
            position: Int?, status: String, errorMsg: String?, streamPath: String,
            source: String? = nil, showTitle: String? = nil, season: Int? = nil,
            episode: Int? = nil, summary: String? = nil, showPreviewUrl: String? = nil,
            chosenVersionId: Int? = nil, versions: [VideoVersion] = [],
            hlsPath: String? = nil, subtitleTracks: [SubtitleTrack] = [],
            sourceFilename: String? = nil, audioLang: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.classification = classification; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
        self.source = source; self.showTitle = showTitle; self.season = season
        self.episode = episode; self.summary = summary; self.showPreviewUrl = showPreviewUrl
        self.chosenVersionId = chosenVersionId; self.versions = versions
        self.hlsPath = hlsPath; self.subtitleTracks = subtitleTracks
        self.sourceFilename = sourceFilename
        self.audioLang = audioLang
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
        self.hlsPath = try c.decodeIfPresent(String.self, forKey: .hlsPath)
        self.subtitleTracks = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitleTracks) ?? []
        self.sourceFilename = try c.decodeIfPresent(String.self, forKey: .sourceFilename)
        self.audioLang = try c.decodeIfPresent(String.self, forKey: .audioLang)
    }

    func withClassification(_ c: String) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
            previewUrl: previewUrl, classification: c, position: position,
            status: status, errorMsg: errorMsg, streamPath: streamPath,
            source: source, showTitle: showTitle, season: season,
            episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
            chosenVersionId: chosenVersionId, versions: versions,
            hlsPath: hlsPath, subtitleTracks: subtitleTracks,
            sourceFilename: sourceFilename, audioLang: audioLang)
    }

    public func withChosenVersion(_ versionId: Int) -> Video {
        withChosenVersion(Optional(versionId))
    }

    public func withChosenVersion(_ versionId: Int?) -> Video {
        let selected = versions.first { $0.id == versionId }
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: classification, position: position,
              status: selected?.status ?? status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: versionId,
              versions: versions.map {
                  VideoVersion(id: $0.id, label: $0.label, status: $0.status,
                               isChosen: $0.id == versionId, audioTracks: $0.audioTracks)
              },
              hlsPath: hlsPath, subtitleTracks: subtitleTracks,
              sourceFilename: sourceFilename, audioLang: audioLang)
    }

    func withAudioLang(_ lang: String) -> Video {
        return Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: classification, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath,
              source: source, showTitle: showTitle, season: season,
              episode: episode, summary: summary, showPreviewUrl: showPreviewUrl,
              chosenVersionId: chosenVersionId, versions: versions,
              hlsPath: hlsPath, subtitleTracks: subtitleTracks,
              sourceFilename: sourceFilename, audioLang: lang)
    }
}
