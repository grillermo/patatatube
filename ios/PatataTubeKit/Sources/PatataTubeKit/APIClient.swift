import Foundation

public enum APIError: Error, Equatable {
    case badStatus(Int)
    case notConfigured
    case decoding(String)
}

public struct ScanResult: Decodable, Equatable, Sendable {
    public let added: Int
    public let updated: Int
    public let skipped: Int

    public init(added: Int, updated: Int, skipped: Int) {
        self.added = added; self.updated = updated; self.skipped = skipped
    }
}

public protocol VideoAPI: Sendable {
    func videos(classification: String?) async throws -> [Video]
    func classifications() async throws -> [String]
    func move(id: Int, direction: String) async throws -> Bool
    func classify(id: Int, classification: String) async throws -> Bool
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool
    func chooseAudio(id: Int, lang: String) async throws -> Bool
    func upload(url: String) async throws -> Int
    func delete(id: Int) async throws -> Bool
    func scanLibrary() async throws -> ScanResult
    func prepare(id: Int) async throws -> String
    func video(id: Int) async throws -> Video
    func imageData(path: String) async throws -> Data
}

public final class APIClient: VideoAPI, @unchecked Sendable {
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    private func base() throws -> URL {
        guard let b = store.baseURL else { throw APIError.notConfigured }
        return b
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }
    }

    public func videos(classification: String? = nil) async throws -> [Video] {
        let endpoint = try base().appendingPathComponent("api/videos")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if let c = classification {
            comps.queryItems = [URLQueryItem(name: "classification", value: c)]
        }
        let (data, response) = try await session.data(from: comps.url!)
        try Self.check(response)
        do {
            return try Self.makeDecoder().decode([Video].self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func classifications() async throws -> [String] {
        let url = try base().appendingPathComponent("api/classifications")
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        struct Envelope: Decodable { let classifications: [String] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).classifications
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func move(id: Int, direction: String) async throws -> Bool {
        try await postOK("api/videos/\(id)/move", body: ["direction": direction])
    }

    public func classify(id: Int, classification: String) async throws -> Bool {
        try await postOK("api/videos/\(id)/classify", body: ["classification": classification])
    }

    public func chooseVersion(id: Int, versionId: Int) async throws -> Bool {
        try await postOK("api/videos/\(id)/version", body: ["version_id": versionId])
    }

    public func chooseAudio(id: Int, lang: String) async throws -> Bool {
        try await postOK("api/videos/\(id)/audio", body: ["lang": lang])
    }

    public func delete(id: Int) async throws -> Bool {
        try await postOK("api/video/\(id)/delete", body: [:])
    }

    public func upload(url: String) async throws -> Int {
        let data = try await authedPost("upload", body: ["url": url])
        struct Result: Decodable { let id: Int }
        do { return try JSONDecoder().decode(Result.self, from: data).id }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func scanLibrary() async throws -> ScanResult {
        let data = try await authedPost("api/library/scan", body: [:])
        do { return try Self.makeDecoder().decode(ScanResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func prepare(id: Int) async throws -> String {
        let data = try await authedPost("api/videos/\(id)/prepare", body: [:])
        struct Result: Decodable { let status: String }
        do { return try JSONDecoder().decode(Result.self, from: data).status }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func video(id: Int) async throws -> Video {
        let data = try await authedGet("api/videos/\(id)")
        do { return try Self.makeDecoder().decode(Video.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Fetches image bytes. Relative paths hit the configured server with Bearer auth;
    /// absolute URLs (e.g. YouTube thumbnails) are fetched as-is.
    public func imageData(path: String) async throws -> Data {
        if let absolute = URL(string: path), absolute.scheme?.hasPrefix("http") == true {
            let (data, response) = try await session.data(from: absolute)
            try Self.check(response)
            return data
        }
        return try await authedGet(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Verifies the configured base URL + token against the server's `/check-auth`.
    /// Returns `true` on 2xx, throws `APIError` on missing config or bad status.
    public func checkAuth() async throws -> Bool {
        guard let token = store.token, !token.isEmpty else { throw APIError.notConfigured }
        var request = URLRequest(url: try base().appendingPathComponent("check-auth"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
        return true
    }

    private func postOK(_ path: String, body: [String: Any]) async throws -> Bool {
        let data = try await authedPost(path, body: body)
        struct Result: Decodable { let ok: Bool }
        do { return try JSONDecoder().decode(Result.self, from: data).ok }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func authedGet(_ path: String) async throws -> Data {
        guard let token = store.token, !token.isEmpty else { throw APIError.notConfigured }
        // appendingPathComponent would percent-encode "?", so build from the full string.
        guard let url = URL(string: path, relativeTo: try base().appendingPathComponent("/")) else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    private func authedPost(_ path: String, body: [String: Any]) async throws -> Data {
        guard let token = store.token, !token.isEmpty else { throw APIError.notConfigured }
        var request = URLRequest(url: try base().appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }
}
