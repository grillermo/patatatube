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

    // Write methods implemented in Task 5.
    public func move(id: Int, direction: String) async throws -> Bool {
        fatalError("implemented in Task 5")
    }
    public func classify(id: Int, classification: String) async throws -> Bool {
        fatalError("implemented in Task 5")
    }
    public func upload(url: String) async throws -> Int {
        fatalError("implemented in Task 5")
    }
}
