import Foundation

public enum APIError: Error, Equatable {
    case badStatus(Int)
    case notConfigured
    case decoding(String)
}

public protocol VideoAPI: Sendable {
    func videos(classification: String?) async throws -> [Video]
    func classifications() async throws -> [String]
    func move(id: Int, direction: String) async throws -> Bool
    func classify(id: Int, classification: String) async throws -> Bool
    func upload(url: String) async throws -> Int
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

    public func upload(url: String) async throws -> Int {
        let data = try await authedPost("upload", body: ["url": url])
        struct Result: Decodable { let id: Int }
        do { return try JSONDecoder().decode(Result.self, from: data).id }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func postOK(_ path: String, body: [String: String]) async throws -> Bool {
        let data = try await authedPost(path, body: body)
        struct Result: Decodable { let ok: Bool }
        do { return try JSONDecoder().decode(Result.self, from: data).ok }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    private func authedPost(_ path: String, body: [String: String]) async throws -> Data {
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
