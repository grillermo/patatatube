import Foundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

public final class CacheManager: @unchecked Sendable {
    private let root: URL
    private let session: URLSession
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var inFlight: [Int: Double] = [:]

    public init(root: URL? = nil, session: URLSession = .shared) {
        self.root = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        self.session = session
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func localURL(for id: Int) -> URL {
        root.appendingPathComponent("\(id).mp4")
    }

    /// Local file URL of a cached preview image, or nil if none is cached.
    public func cachedPreviewURL(for id: Int) -> URL? {
        let prefix = "\(id).preview."
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return root.appendingPathComponent(name)
    }

    public func state(for id: Int) -> CacheState {
        if fileManager.fileExists(atPath: localURL(for: id).path) { return .cached }
        return lock.withLock {
            inFlight[id].map { .downloading($0) } ?? .notCached
        }
    }

    public func download(id: Int, from remote: URL, preview: URL? = nil,
                         bearerToken: String? = nil) async throws {
        lock.withLock { inFlight[id] = 0 }
        do {
            var request = URLRequest(url: remote)
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            let (tempURL, response) = try await session.download(for: request)
            lock.withLock { inFlight[id] = nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.badStatus(http.statusCode)
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = localURL(for: id)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            lock.withLock { inFlight[id] = nil }
            throw error
        }
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
    }

    private func cachePreview(id: Int, from remote: URL, bearerToken: String? = nil) async throws {
        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        let ext = remote.pathExtension.lowercased()
        let safeExt = (1...4).contains(ext.count) && ext.allSatisfy(\.isLetter) ? ext : "jpg"
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("\(id).preview.\(safeExt)")
        try? fileManager.removeItem(at: destination)
        try data.write(to: destination)
    }
}
