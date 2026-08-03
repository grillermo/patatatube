import Foundation

/// Persists the `api/videos` response to disk so the app works offline.
public protocol VideoListCaching: Sendable {
    func save(_ videos: [Video], feed: Feed)
    func load(feed: Feed) -> [Video]?
    func clear()
}

public final class VideoListCache: VideoListCaching, @unchecked Sendable {
    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("video-lists")
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private func fileURL(_ feed: Feed) -> URL {
        root.appendingPathComponent("\(feed.storageKey).json")
    }

    public func save(_ videos: [Video], feed: Feed) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: fileURL(feed), options: .atomic)
    }

    public func load(feed: Feed) -> [Video]? {
        guard let data = try? Data(contentsOf: fileURL(feed)) else { return nil }
        return try? JSONDecoder().decode([Video].self, from: data)
    }

    public func clear() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
