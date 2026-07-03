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

    public func state(for id: Int) -> CacheState {
        if fileManager.fileExists(atPath: localURL(for: id).path) { return .cached }
        return lock.withLock {
            inFlight[id].map { .downloading($0) } ?? .notCached
        }
    }

    public func download(id: Int, from remote: URL) async throws {
        lock.withLock { inFlight[id] = 0 }
        do {
            let (tempURL, response) = try await session.download(from: remote)
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
    }
}
