import Foundation

public enum APIError: Error, Equatable {
    case badStatus(Int)
    case notConfigured
    case serverChanged
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
    func videos(feed: Feed) async throws -> [Video]
    func groups() async throws -> [VideoGroup]
    func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup
    func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup
    func setGroup(id: Int, groupID: Int) async throws -> Bool
    func promote(id: Int, kind: PlexKind) async throws -> Bool
    func chooseVersion(id: Int, versionId: Int) async throws -> Bool
    func chooseAudio(id: Int, lang: String) async throws -> Bool
    func chooseSubtitle(id: Int, lang: String?) async throws -> Bool
    func savePosition(id: Int, secs: Double) async throws
    func savePosition(
        id: Int, secs: Double, destinationServerIdentity: String
    ) async throws
    func upload(url: String, groupID: Int?) async throws -> Int
    func delete(id: Int) async throws -> Bool
    func scanLibrary() async throws -> ScanResult
    func prepare(id: Int, bulk: Bool) async throws -> String
    func video(id: Int) async throws -> Video
    func imageData(path: String) async throws -> Data
    func jobs() async throws -> JobsSnapshot
}

public extension VideoAPI {
    // Defaulted so the many test doubles conforming to this protocol don't all
    // have to implement a feature they don't exercise. The real client
    // overrides them.
    func groups() async throws -> [VideoGroup] { [] }
    func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup {
        throw APIError.notConfigured
    }
    func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup {
        throw APIError.notConfigured
    }
    func setGroup(id: Int, groupID: Int) async throws -> Bool { false }
    func promote(id: Int, kind: PlexKind) async throws -> Bool { false }
    func chooseSubtitle(id: Int, lang: String?) async throws -> Bool { false }

    func savePosition(
        id: Int, secs: Double, destinationServerIdentity: String
    ) async throws {
        try await savePosition(id: id, secs: secs)
    }
}

public final class APIClient: VideoAPI, JobsAPI, @unchecked Sendable {
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

    /// Every API response funnels through here, so this is the one place that
    /// sees all of them. Paths and statuses only — never tokens, never bodies.
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        DevLog.event(.net, "\(http.statusCode) \(http.url?.path ?? "-")", [
            "status": "\(http.statusCode)",
            "path": http.url?.path ?? "-",
        ])
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }
    }

    public func videos(feed: Feed = .all) async throws -> [Video] {
        let endpoint = try base().appendingPathComponent("api/videos")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let items = feed.queryItems
        comps.queryItems = items.isEmpty ? nil : items
        let (data, response) = try await session.data(from: comps.url!)
        try Self.check(response)
        do {
            return try Self.makeDecoder().decode([Video].self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func groups() async throws -> [VideoGroup] {
        let (data, response) = try await session.data(
            from: try base().appendingPathComponent("api/groups")
        )
        try Self.check(response)
        struct Envelope: Decodable { let groups: [VideoGroup] }
        do {
            return try Self.makeDecoder().decode(Envelope.self, from: data)
                .groups.sorted { $0.position < $1.position }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func createGroup(name: String, label: String, emoji: String?) async throws -> VideoGroup {
        let data = try await authedPost(
            "api/groups", body: ["name": name, "label": label, "emoji": emoji ?? NSNull()]
        )
        do { return try Self.makeDecoder().decode(VideoGroup.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func updateGroup(id: Int, label: String?, emoji: String?) async throws -> VideoGroup {
        var body: [String: Any] = ["emoji": emoji ?? NSNull()]
        if let label { body["label"] = label }
        let data = try await authedRequest("api/groups/\(id)", method: "PATCH", body: body)
        do { return try Self.makeDecoder().decode(VideoGroup.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// Separate from `updateGroup`, which always sends `emoji` — patching this
    /// toggle through it would clear the group's cover.
    public func setGroupDisplayTitles(id: Int, _ on: Bool) async throws -> VideoGroup {
        let data = try await authedRequest(
            "api/groups/\(id)", method: "PATCH", body: ["display_titles": on]
        )
        do { return try Self.makeDecoder().decode(VideoGroup.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func setGroup(id: Int, groupID: Int) async throws -> Bool {
        try await postOK("api/videos/\(id)/group", body: ["group_id": groupID])
    }

    public func promote(id: Int, kind: PlexKind) async throws -> Bool {
        try await postOK("api/videos/\(id)/promote", body: ["kind": kind.rawValue])
    }

    public func chooseVersion(id: Int, versionId: Int) async throws -> Bool {
        try await postOK("api/videos/\(id)/version", body: ["version_id": versionId])
    }

    public func chooseAudio(id: Int, lang: String) async throws -> Bool {
        try await postOK("api/videos/\(id)/audio", body: ["lang": lang])
    }

    public func chooseSubtitle(id: Int, lang: String?) async throws -> Bool {
        try await postOK("api/videos/\(id)/subtitle", body: ["lang": lang ?? NSNull()])
    }

    /// Reports where playback got to. The server answers 204 with no body, so
    /// there is nothing to decode — a throw is the only failure signal.
    public func savePosition(id: Int, secs: Double) async throws {
        let destination = ResumePositionStore.normalizedServerIdentity(try base())
        try await savePosition(
            id: id, secs: secs, destinationServerIdentity: destination
        )
    }

    public func savePosition(
        id: Int, secs: Double, destinationServerIdentity: String
    ) async throws {
        _ = try await authedPost(
            "api/videos/\(id)/position",
            body: ["secs": secs],
            destinationServerIdentity: destinationServerIdentity
        )
    }

    public func delete(id: Int) async throws -> Bool {
        try await postOK("api/video/\(id)/delete", body: [:])
    }

    public func upload(url: String, groupID: Int?) async throws -> Int {
        var body: [String: Any] = ["url": url]
        if let groupID { body["group_id"] = groupID }
        let data = try await authedPost("upload", body: body)
        struct Result: Decodable { let id: Int }
        do { return try JSONDecoder().decode(Result.self, from: data).id }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func scanLibrary() async throws -> ScanResult {
        let data = try await authedPost("api/library/scan", body: [:])
        do { return try Self.makeDecoder().decode(ScanResult.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func prepare(id: Int, bulk: Bool = false) async throws -> String {
        let body: [String: String] = bulk ? ["priority": "bulk"] : [:]
        let data = try await authedPost("api/videos/\(id)/prepare", body: body)
        struct Result: Decodable { let status: String }
        do { return try JSONDecoder().decode(Result.self, from: data).status }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func video(id: Int) async throws -> Video {
        let data = try await authedGet("api/videos/\(id)")
        do { return try Self.makeDecoder().decode(Video.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    public func jobs() async throws -> JobsSnapshot {
        let data = try await authedGet("api/jobs")
        do { return try Self.makeDecoder().decode(JobsSnapshot.self, from: data) }
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
        try await authedRequest(path, method: "GET")
    }

    private func authedPost(
        _ path: String,
        body: [String: Any],
        destinationServerIdentity: String? = nil
    ) async throws -> Data {
        try await authedRequest(
            path, method: "POST", body: body,
            destinationServerIdentity: destinationServerIdentity
        )
    }

    private func authedRequest(
        _ path: String,
        method: String,
        body: [String: Any]? = nil,
        destinationServerIdentity: String? = nil
    ) async throws -> Data {
        guard let token = store.token, !token.isEmpty else { throw APIError.notConfigured }
        let baseURL = try base()
        if let destinationServerIdentity,
           ResumePositionStore.normalizedServerIdentity(baseURL) != destinationServerIdentity {
            throw APIError.serverChanged
        }
        guard let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("/")) else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }
}
