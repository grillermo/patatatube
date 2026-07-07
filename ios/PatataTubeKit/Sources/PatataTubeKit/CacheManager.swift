import Foundation

public enum CacheState: Equatable, Sendable {
    case notCached
    case downloading(Double)
    case cached
}

public final class CacheManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let root: URL
    private var session: URLSession!
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var inFlight: [Int: Double] = [:]
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var idByTask: [Int: Int] = [:]
    private var completedResults: [Int: Result<URL, Error>] = [:]

    public init(root: URL? = nil, configuration: URLSessionConfiguration = .default) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("videos")
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        // Visible in the Files app (Documents), but keep it out of iCloud/device
        // backups - these MP4s are re-downloadable, not user data.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = self.root
        try? dir.setResourceValues(values)
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
        try await downloadVideo(id: id, from: remote, bearerToken: bearerToken)
        // Best-effort: a missing preview must not fail the cached video.
        if let preview { try? await cachePreview(id: id, from: preview, bearerToken: bearerToken) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let id = lock.withLock({ idByTask[downloadTask.taskIdentifier] }) else { return }
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        } else {
            progress = 0
        }
        lock.withLock { inFlight[id] = progress }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let taskIdentifier = downloadTask.taskIdentifier
        guard let id = lock.withLock({ idByTask[taskIdentifier] }) else { return }

        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(APIError.badStatus(http.statusCode))
        } else {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = localURL(for: id)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: location, to: destination)
                try? fileManager.removeItem(at: resumeURL(for: id))
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }

        lock.withLock { completedResults[taskIdentifier] = result }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        let taskIdentifier = task.taskIdentifier
        guard let id = lock.withLock({ idByTask[taskIdentifier] }) else { return }

        if let error {
            persistResumeData(from: error, for: id)
            finish(id: id, taskIdentifier: taskIdentifier, result: .failure(error))
            return
        }

        let result = lock.withLock {
            completedResults[taskIdentifier] ?? .failure(URLError(.unknown))
        }
        finish(id: id, taskIdentifier: taskIdentifier, result: result)
    }

    private func downloadVideo(id: Int, from remote: URL,
                               bearerToken: String? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(id: id, from: remote, bearerToken: bearerToken)
            lock.withLock {
                inFlight[id] = 0
                continuations[id] = continuation
                idByTask[task.taskIdentifier] = id
            }
            task.resume()
        }
    }

    private func downloadTask(id: Int, from remote: URL,
                              bearerToken: String? = nil) -> URLSessionDownloadTask {
        if let resumeData = try? Data(contentsOf: resumeURL(for: id)), !resumeData.isEmpty {
            return session.downloadTask(withResumeData: resumeData)
        }

        var request = URLRequest(url: remote)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return session.downloadTask(with: request)
    }

    private func finish(id: Int, taskIdentifier: Int, result: Result<URL, Error>) {
        let continuation = lock.withLock {
            inFlight[id] = nil
            idByTask[taskIdentifier] = nil
            completedResults[taskIdentifier] = nil
            return continuations.removeValue(forKey: id)
        }

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func persistResumeData(from error: Error, for id: Int) {
        let userInfo = (error as NSError).userInfo
        guard let data = userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty else {
            return
        }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(for: id), options: .atomic)
    }

    private func resumeURL(for id: Int) -> URL {
        root.appendingPathComponent("\(id).resume")
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
