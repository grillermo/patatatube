import Foundation

/// Sends files (screenshots and the like) to scripts/devlog/server.py, which
/// stores them under log/screens/<name>. Files skip the record buffer, because
/// one image would crowd out many records. When too many are already in flight,
/// new ones are dropped, so the observed code never queues behind the network.
public final class DevLogUploader: @unchecked Sendable {
    public static let maxInFlight = 4
    /// Matches the server's per-file cap.
    public static let maxBytes = 8 * 1024 * 1024

    private let uploadURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight = 0

    public init(endpoint: URL, configuration: URLSessionConfiguration = DevLogHTTPSink.defaultConfiguration()) {
        self.uploadURL = endpoint.appendingPathComponent("upload")
        self.session = URLSession(configuration: configuration)
    }

    /// Returns false when the file was dropped (cap reached, too big, bad name).
    @discardableResult
    public func upload(name: String, data: Data) -> Bool {
        guard data.count <= Self.maxBytes,
              var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return false }

        let accepted: Bool = lock.withLock {
            guard inFlight < Self.maxInFlight else { return false }
            inFlight += 1
            return true
        }
        guard accepted else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        session.uploadTask(with: request, from: data) { [weak self] _, _, _ in
            guard let self else { return }
            self.lock.withLock { self.inFlight -= 1 }
        }.resume()
        return true
    }
}
