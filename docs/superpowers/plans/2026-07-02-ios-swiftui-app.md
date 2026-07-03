# PatataTube iOS SwiftUI App Implementation Plan

> **STATUS: COMPLETE (2026-07-02)**
> 
> Commit range: `9b17a4b..8809b84`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build a native SwiftUI iPad app alongside the existing web PWA that consumes the server JSON API, reaches feature parity with the web UI, and caches videos locally for offline playback.

**Architecture:** Two-part iOS project in `ios/`. A pure-Swift SPM package `PatataTubeKit` holds all testable logic (models, `APIClient`, `CredentialStore`, `CacheManager`, `VideoStore`) using only Foundation + Combine, so it runs headless under `swift test` on macOS. A thin Xcode app `PatataTube` (SwiftUI + AVKit) depends on the package and holds only views + app wiring, verified manually in the simulator/device.

**Tech Stack:** SwiftUI, iPadOS 17+, AVKit/AVFoundation, async/await `URLSession`, Combine, Swift Testing. Build tooling: Swift 6.2 / Xcode 26.3, `xcodegen` for reproducible project generation.

## Global Constraints

- Deployment target: iPadOS 17.0+ (iPad-first, `TARGETED_DEVICE_FAMILY = 2`).
- Swift 6 language mode; Swift Testing framework (`import Testing`, `@Test`, `#expect`) — never XCTest.
- `PatataTubeKit` depends ONLY on Foundation + Combine (no UIKit/SwiftUI/AVKit) so `swift test` runs on macOS. AVKit/SwiftUI live only in the app target.
- No third-party runtime dependencies. `xcodegen` is a build-time tool only (`brew install xcodegen`).
- Server JSON API (already live on `main`) is the contract — do not change the server. Exact shapes:
  - `GET /api/classifications` → `{"classifications": ["children","adults","education","entertainment"]}`
  - `GET /api/videos?classification=<opt>` → JSON array; each item:
    `{id:Int, url:String, title:String?, platform:String?, source_key:String?, preview_url:String?, classification:String, position:Int?, status:String, error_msg:String?, stream_path:String}`
  - `POST /api/videos/{id}/move` — Bearer token, body `{"direction":"up"|"down"}` → `{"ok":Bool}`
  - `POST /api/videos/{id}/classify` — Bearer token, body `{"classification":"<one of CLASSIFICATIONS>"}` → `{"ok":Bool}`
  - `POST /upload` — Bearer token, body `{"url":"<string>"}` → `{"id":Int, "status":"queued"}`
  - `GET /videos/{id}/stream` — byte-range mp4, unauthenticated.
- Read endpoints (`/api/videos`, `/api/classifications`, `/stream`) are unauthenticated. Write endpoints require `Authorization: Bearer <token>`.
- Server base URL + Bearer token are user-configured, persisted via `KeychainCredentialStore` (token in Keychain, base URL in `UserDefaults`).
- Cache location: `<Caches>/videos/{id}.mp4`. No eviction logic (rely on system Caches eviction — YAGNI).

---

### Task 1: SPM package scaffold `PatataTubeKit`

**Files:**
- Create: `ios/PatataTubeKit/Package.swift`
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/PatataTubeKit.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/ScaffoldTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable/testable package named `PatataTubeKit` with a `PatataTubeKitTests` target; establishes that `swift test` runs in `ios/PatataTubeKit/`.

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/ScaffoldTests.swift
import Testing
@testable import PatataTubeKit

@Test func packageIsWired() {
    #expect(PatataTubeKit.marker == "patatatube")
}
```

- [x] **Step 2: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PatataTubeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PatataTubeKit", targets: ["PatataTubeKit"]),
    ],
    targets: [
        .target(name: "PatataTubeKit"),
        .testTarget(name: "PatataTubeKitTests", dependencies: ["PatataTubeKit"]),
    ]
)
```

- [x] **Step 3: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test`
Expected: FAIL — compile error, `PatataTubeKit.marker` / type `PatataTubeKit` not found.

- [x] **Step 4: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/PatataTubeKit.swift
public enum PatataTubeKit {
    public static let marker = "patatatube"
}
```

- [x] **Step 5: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test`
Expected: PASS (1 test).

- [x] **Step 6: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): scaffold PatataTubeKit SPM package"
```

---

### Task 2: `Video` model + JSON decoding

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct Video: Codable, Identifiable, Equatable, Sendable` with fields
    `id:Int, url:String, title:String?, platform:String?, sourceKey:String?, previewUrl:String?, classification:String, position:Int?, status:String, errorMsg:String?, streamPath:String`.
  - `func withClassification(_ c: String) -> Video` (internal helper for optimistic updates).
  - Decoding uses `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, so server `preview_url`→`previewUrl`, `source_key`→`sourceKey`, `error_msg`→`errorMsg`, `stream_path`→`streamPath`.

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

private let sampleJSON = """
[
  {"id": 7, "url": "https://youtu.be/abc", "title": "Hi", "platform": "youtube",
   "source_key": "abc12345678", "preview_url": "https://img/abc.jpg",
   "classification": "children", "position": 3, "status": "completed",
   "error_msg": null, "stream_path": "/videos/7/stream"},
  {"id": 8, "url": "https://x/y", "title": null, "platform": null,
   "source_key": null, "preview_url": null, "classification": "adults",
   "position": null, "status": "pending", "error_msg": "boom",
   "stream_path": "/videos/8/stream"}
]
""".data(using: .utf8)!

@Test func decodesVideoArrayWithSnakeCase() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let videos = try decoder.decode([Video].self, from: sampleJSON)

    #expect(videos.count == 2)
    #expect(videos[0].id == 7)
    #expect(videos[0].previewUrl == "https://img/abc.jpg")
    #expect(videos[0].sourceKey == "abc12345678")
    #expect(videos[0].streamPath == "/videos/7/stream")
    #expect(videos[1].title == nil)
    #expect(videos[1].position == nil)
    #expect(videos[1].errorMsg == "boom")
}

@Test func withClassificationReplacesOnlyClassification() {
    let v = Video(id: 1, url: "u", title: "t", platform: nil, sourceKey: nil,
                  previewUrl: nil, classification: "children", position: 1,
                  status: "completed", errorMsg: nil, streamPath: "/videos/1/stream")
    let updated = v.withClassification("adults")
    #expect(updated.classification == "adults")
    #expect(updated.id == 1)
    #expect(updated.status == "completed")
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoTests`
Expected: FAIL — `Video` type not found.

- [x] **Step 3: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/Video.swift
public struct Video: Codable, Identifiable, Equatable, Sendable {
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

    public init(id: Int, url: String, title: String?, platform: String?,
                sourceKey: String?, previewUrl: String?, classification: String,
                position: Int?, status: String, errorMsg: String?, streamPath: String) {
        self.id = id; self.url = url; self.title = title; self.platform = platform
        self.sourceKey = sourceKey; self.previewUrl = previewUrl
        self.classification = classification; self.position = position
        self.status = status; self.errorMsg = errorMsg; self.streamPath = streamPath
    }

    func withClassification(_ c: String) -> Video {
        Video(id: id, url: url, title: title, platform: platform, sourceKey: sourceKey,
              previewUrl: previewUrl, classification: c, position: position,
              status: status, errorMsg: errorMsg, streamPath: streamPath)
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter VideoTests`
Expected: PASS (2 tests).

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add Video model with snake_case decoding"
```

---

### Task 3: `CredentialStore` protocol + implementations

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CredentialStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CredentialStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public protocol CredentialStore: AnyObject { var baseURL: URL? { get set }; var token: String? { get set } }`
  - `public final class InMemoryCredentialStore: CredentialStore` (used by tests and previews).
  - `public final class KeychainCredentialStore: CredentialStore` (real impl: base URL in `UserDefaults`, token in Keychain). Not unit-tested (requires entitlements); manually verified in Task 9.

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/CredentialStoreTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

@Test func inMemoryStoreRoundTrips() {
    let store: CredentialStore = InMemoryCredentialStore()
    #expect(store.baseURL == nil)
    #expect(store.token == nil)

    store.baseURL = URL(string: "https://example.test")
    store.token = "secret"
    #expect(store.baseURL?.absoluteString == "https://example.test")
    #expect(store.token == "secret")
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CredentialStoreTests`
Expected: FAIL — `CredentialStore` / `InMemoryCredentialStore` not found.

- [x] **Step 3: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/CredentialStore.swift
import Foundation

public protocol CredentialStore: AnyObject {
    var baseURL: URL? { get set }
    var token: String? { get set }
}

public final class InMemoryCredentialStore: CredentialStore {
    public var baseURL: URL?
    public var token: String?
    public init(baseURL: URL? = nil, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }
}

public final class KeychainCredentialStore: CredentialStore {
    private let account = "patatatube.uploadToken"
    private let service = "patatatube"
    private let baseURLKey = "patatatube.baseURL"
    private let defaults = UserDefaults.standard

    public init() {}

    public var baseURL: URL? {
        get { defaults.string(forKey: baseURLKey).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: baseURLKey) }
    }

    public var token: String? {
        get {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            _ = query
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue, let data = value.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CredentialStoreTests`
Expected: PASS (1 test).

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add CredentialStore protocol + keychain/in-memory impls"
```

---

### Task 4: `MockURLProtocol` test helper + `APIClient` read endpoints

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Create: `ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift`

**Interfaces:**
- Consumes: `Video` (Task 2), `CredentialStore` (Task 3).
- Produces:
  - `public enum APIError: Error, Equatable { case badStatus(Int); case notConfigured; case decoding(String) }`
  - `public protocol VideoAPI` with the five async methods (full signatures below); `APIClient` conforms.
  - `public final class APIClient: VideoAPI` — `init(store: CredentialStore, session: URLSession = .shared)`.
  - This task implements `videos(classification:)` and `classifications()`. Write methods land in Task 5.
  - Test helper `MockURLProtocol` + `func mockSession() -> URLSession`.

- [x] **Step 1: Write the mock helper**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/MockURLProtocol.swift
import Foundation

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

func jsonResponse(_ url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
}
```

- [x] **Step 2: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientReadTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient() -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: "tok")
    return APIClient(store: store, session: mockSession())
}

@Test func fetchesVideos() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/api/videos")
        let body = """
        [{"id":1,"url":"u","title":"t","platform":"youtube","source_key":"k",
          "preview_url":"p","classification":"children","position":1,
          "status":"completed","error_msg":null,"stream_path":"/videos/1/stream"}]
        """.data(using: .utf8)!
        return (jsonResponse(req.url!), body)
    }
    let videos = try await makeClient().videos(classification: nil)
    #expect(videos.count == 1)
    #expect(videos[0].previewUrl == "p")
}

@Test func fetchesVideosWithClassificationQuery() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.query == "classification=adults")
        return (jsonResponse(req.url!), "[]".data(using: .utf8)!)
    }
    let videos = try await makeClient().videos(classification: "adults")
    #expect(videos.isEmpty)
}

@Test func fetchesClassifications() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/api/classifications")
        let body = #"{"classifications":["children","adults"]}"#.data(using: .utf8)!
        return (jsonResponse(req.url!), body)
    }
    let list = try await makeClient().classifications()
    #expect(list == ["children", "adults"])
}

@Test func throwsOnBadStatus() async {
    MockURLProtocol.handler = { req in (jsonResponse(req.url!, status: 500), Data()) }
    await #expect(throws: APIError.badStatus(500)) {
        _ = try await makeClient().videos(classification: nil)
    }
}

@Test func throwsWhenBaseURLMissing() async {
    let store = InMemoryCredentialStore(baseURL: nil, token: "t")
    let client = APIClient(store: store, session: mockSession())
    await #expect(throws: APIError.notConfigured) {
        _ = try await client.videos(classification: nil)
    }
}
```

- [x] **Step 3: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientReadTests`
Expected: FAIL — `APIClient` / `APIError` / `VideoAPI` not found.

- [x] **Step 4: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift
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
```

- [x] **Step 5: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientReadTests`
Expected: PASS (5 tests). All prior tests still green: `cd ios/PatataTubeKit && swift test`.

- [x] **Step 6: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add APIClient read endpoints + URLProtocol test harness"
```

---

### Task 5: `APIClient` write endpoints (move/classify/upload)

**Files:**
- Modify: `ios/PatataTubeKit/Sources/PatataTubeKit/APIClient.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientWriteTests.swift`

**Interfaces:**
- Consumes: `APIClient` scaffold + `VideoAPI` (Task 4).
- Produces: working `move(id:direction:) -> Bool`, `classify(id:classification:) -> Bool`, `upload(url:) -> Int`. All send `POST` with `Content-Type: application/json` and `Authorization: Bearer <token>`; throw `APIError.notConfigured` when token missing/empty.

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/APIClientWriteTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient(token: String? = "tok") -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: token)
    return APIClient(store: store, session: mockSession())
}

@Test func moveSendsAuthAndBody() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/api/videos/9/move")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = req.httpBodyData()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(json["direction"] == "up")
        return (jsonResponse(req.url!), #"{"ok":true}"#.data(using: .utf8)!)
    }
    let ok = try await makeClient().move(id: 9, direction: "up")
    #expect(ok == true)
}

@Test func classifySendsBody() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/api/videos/3/classify")
        let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: String]
        #expect(json["classification"] == "education")
        return (jsonResponse(req.url!), #"{"ok":false}"#.data(using: .utf8)!)
    }
    let ok = try await makeClient().classify(id: 3, classification: "education")
    #expect(ok == false)
}

@Test func uploadReturnsNewId() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/upload")
        let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: String]
        #expect(json["url"] == "https://youtu.be/xyz")
        return (jsonResponse(req.url!, status: 202), #"{"id":42,"status":"queued"}"#.data(using: .utf8)!)
    }
    let id = try await makeClient().upload(url: "https://youtu.be/xyz")
    #expect(id == 42)
}

@Test func writeThrowsWithoutToken() async {
    await #expect(throws: APIError.notConfigured) {
        _ = try await makeClient(token: nil).move(id: 1, direction: "up")
    }
}
```

Add this helper to the bottom of `MockURLProtocol.swift` (the `URLProtocol` stub strips `httpBody` into a stream, so read it back):

```swift
// append to MockURLProtocol.swift
extension URLRequest {
    func httpBodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientWriteTests`
Expected: FAIL / crash — write methods still `fatalError`.

- [x] **Step 3: Write minimal implementation** — replace the three `fatalError` stubs in `APIClient.swift`

```swift
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
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter APIClientWriteTests`
Expected: PASS (4 tests). Full suite: `cd ios/PatataTubeKit && swift test`.

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add APIClient move/classify/upload write endpoints"
```

---

### Task 6: `CacheManager` — local mp4 download + state

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift`

**Interfaces:**
- Consumes: `APIError` (Task 4).
- Produces:
  - `public enum CacheState: Equatable, Sendable { case notCached; case downloading(Double); case cached }`
  - `public final class CacheManager` — `init(root: URL? = nil, session: URLSession = .shared)`; `func localURL(for id: Int) -> URL`; `func state(for id: Int) -> CacheState`; `func download(id: Int, from remote: URL) async throws`. Default `root` = `<Caches>/videos`.

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/CacheManagerTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

private func tempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("catch-\(UUID().uuidString)")
    return dir
}

@Test func localURLUsesIdAndMp4() {
    let root = tempRoot()
    let manager = CacheManager(root: root, session: mockSession())
    #expect(manager.localURL(for: 5).lastPathComponent == "5.mp4")
}

@Test func stateIsNotCachedThenCachedAfterDownload() async throws {
    let root = tempRoot()
    let manager = CacheManager(root: root, session: mockSession())
    #expect(manager.state(for: 11) == .notCached)

    MockURLProtocol.handler = { req in
        (jsonResponse(req.url!), Data([0x00, 0x01, 0x02, 0x03]))
    }
    try await manager.download(id: 11, from: URL(string: "https://srv.test/videos/11/stream")!)

    #expect(manager.state(for: 11) == .cached)
    let saved = try Data(contentsOf: manager.localURL(for: 11))
    #expect(saved == Data([0x00, 0x01, 0x02, 0x03]))
}

@Test func downloadThrowsOnBadStatus() async {
    let manager = CacheManager(root: tempRoot(), session: mockSession())
    MockURLProtocol.handler = { req in (jsonResponse(req.url!, status: 404), Data()) }
    await #expect(throws: APIError.badStatus(404)) {
        try await manager.download(id: 1, from: URL(string: "https://srv.test/x")!)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: FAIL — `CacheManager` / `CacheState` not found.

- [x] **Step 3: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/CacheManager.swift
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
        lock.lock(); defer { lock.unlock() }
        if let progress = inFlight[id] { return .downloading(progress) }
        return .notCached
    }

    public func download(id: Int, from remote: URL) async throws {
        lock.lock(); inFlight[id] = 0; lock.unlock()
        defer { lock.lock(); inFlight[id] = nil; lock.unlock() }

        let (tempURL, response) = try await session.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = localURL(for: id)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: tempURL, to: destination)
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter CacheManagerTests`
Expected: PASS (3 tests).

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add CacheManager for offline mp4 download"
```

---

### Task 7: `VideoStore` — observable state + optimistic mutations

**Files:**
- Create: `ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift`
- Test: `ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift`

**Interfaces:**
- Consumes: `Video` (Task 2), `VideoAPI` (Task 4).
- Produces:
  - `@MainActor public final class VideoStore: ObservableObject` — `init(api: VideoAPI)`.
  - `@Published public private(set) var videos: [Video]`, `@Published public var filter: String?`, `@Published public private(set) var isLoading: Bool`, `@Published public var errorText: String?`.
  - `func load() async`, `func classify(id: Int, to: String) async` (optimistic + revert on `ok==false`/throw), `func move(id: Int, direction: String) async` (refetch on success), `func upload(url: String) async` (refetch after).

- [x] **Step 1: Write the failing test**

```swift
// ios/PatataTubeKit/Tests/PatataTubeKitTests/VideoStoreTests.swift
import Testing
import Foundation
@testable import PatataTubeKit

private func makeVideo(id: Int, classification: String = "children") -> Video {
    Video(id: id, url: "u\(id)", title: "t\(id)", platform: nil, sourceKey: nil,
          previewUrl: nil, classification: classification, position: id,
          status: "completed", errorMsg: nil, streamPath: "/videos/\(id)/stream")
}

private final class FakeAPI: VideoAPI, @unchecked Sendable {
    var videosToReturn: [Video] = []
    var classifyResult = true
    var moveResult = true
    var uploadId = 100
    var throwOnClassify = false
    private(set) var loadCount = 0

    func videos(classification: String?) async throws -> [Video] {
        loadCount += 1
        if let c = classification { return videosToReturn.filter { $0.classification == c } }
        return videosToReturn
    }
    func classifications() async throws -> [String] { ["children", "adults"] }
    func move(id: Int, direction: String) async throws -> Bool { moveResult }
    func classify(id: Int, classification: String) async throws -> Bool {
        if throwOnClassify { throw APIError.badStatus(500) }
        return classifyResult
    }
    func upload(url: String) async throws -> Int { uploadId }
}

@MainActor @Test func loadPopulatesVideos() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1), makeVideo(id: 2)]
    let store = VideoStore(api: api)
    await store.load()
    #expect(store.videos.count == 2)
    #expect(store.isLoading == false)
    #expect(store.errorText == nil)
}

@MainActor @Test func classifyOptimisticallyUpdatesThenKeepsOnSuccess() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.classifyResult = true
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "adults")
}

@MainActor @Test func classifyRevertsWhenServerReturnsNotOk() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.classifyResult = false
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "children")
}

@MainActor @Test func classifyRevertsAndSetsErrorOnThrow() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1, classification: "children")]
    api.throwOnClassify = true
    let store = VideoStore(api: api)
    await store.load()
    await store.classify(id: 1, to: "adults")
    #expect(store.videos[0].classification == "children")
    #expect(store.errorText != nil)
}

@MainActor @Test func moveRefetchesOnSuccess() async {
    let api = FakeAPI(); api.videosToReturn = [makeVideo(id: 1)]
    let store = VideoStore(api: api)
    await store.load()          // loadCount == 1
    await store.move(id: 1, direction: "up")  // success -> reload
    #expect(api.loadCount == 2)
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStoreTests`
Expected: FAIL — `VideoStore` not found.

- [x] **Step 3: Write minimal implementation**

```swift
// ios/PatataTubeKit/Sources/PatataTubeKit/VideoStore.swift
import Foundation
import Combine

@MainActor
public final class VideoStore: ObservableObject {
    @Published public private(set) var videos: [Video] = []
    @Published public var filter: String?
    @Published public private(set) var isLoading = false
    @Published public var errorText: String?

    private let api: VideoAPI

    public init(api: VideoAPI) { self.api = api }

    public func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            videos = try await api.videos(classification: filter)
        } catch {
            errorText = String(describing: error)
        }
    }

    public func classify(id: Int, to classification: String) async {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos
        videos[index] = videos[index].withClassification(classification)
        do {
            let ok = try await api.classify(id: id, classification: classification)
            if !ok { videos = previous }
        } catch {
            videos = previous
            errorText = String(describing: error)
        }
    }

    public func move(id: Int, direction: String) async {
        do {
            let ok = try await api.move(id: id, direction: direction)
            if ok { await load() }
        } catch {
            errorText = String(describing: error)
        }
    }

    public func upload(url: String) async {
        do {
            _ = try await api.upload(url: url)
            await load()
        } catch {
            errorText = String(describing: error)
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ios/PatataTubeKit && swift test --filter VideoStoreTests`
Expected: PASS (5 tests). Full suite green: `cd ios/PatataTubeKit && swift test`.

- [x] **Step 5: Commit**

```bash
git add ios/PatataTubeKit
git commit -m "feat(ios): add VideoStore with optimistic classify/move/upload"
```

---

### Task 8: Xcode app scaffold + Settings + app wiring

**Files:**
- Create: `ios/PatataTube/project.yml`
- Create: `ios/PatataTube/Sources/PatataTubeApp.swift`
- Create: `ios/PatataTube/Sources/AppModel.swift`
- Create: `ios/PatataTube/Sources/SettingsView.swift`
- Create: `ios/.gitignore`

**Interfaces:**
- Consumes: `PatataTubeKit` (all prior tasks) via local SPM dependency.
- Produces: a buildable iPad app target `PatataTube` with an `AppModel` (holds `KeychainCredentialStore`, `APIClient`, `CacheManager`, `VideoStore`) injected as `@StateObject`, and a `SettingsView` to edit base URL + token.

**Note:** This task's deliverable is a *compiling, launchable* app shell — verified by `xcodebuild ... build`, not `swift test`. TDD does not apply to the SwiftUI view layer; verification is a successful build + manual launch.

- [x] **Step 1: Install xcodegen (once)**

Run: `which xcodegen || brew install xcodegen`
Expected: prints a path or installs it.

- [x] **Step 2: Create `ios/PatataTube/project.yml`**

```yaml
name: PatataTube
options:
  bundleIdPrefix: com.patatatube
  deploymentTarget:
    iOS: "17.0"
packages:
  PatataTubeKit:
    path: ../PatataTubeKit
targets:
  PatataTube:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - Sources
    dependencies:
      - package: PatataTubeKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.patatatube.app
        TARGETED_DEVICE_FAMILY: "2"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        SWIFT_VERSION: "6.0"
        INFOPLIST_KEY_NSAppTransportSecurity_NSAllowsLocalNetworking: YES
```

- [x] **Step 3: Create `ios/.gitignore`**

```gitignore
PatataTube/PatataTube.xcodeproj/
.build/
xcuserdata/
*.xcworkspace/xcuserdata/
```

- [x] **Step 4: Create `AppModel.swift`**

```swift
// ios/PatataTube/Sources/AppModel.swift
import Foundation
import Combine
import PatataTubeKit

@MainActor
final class AppModel: ObservableObject {
    let credentials: CredentialStore
    let cache: CacheManager
    let store: VideoStore

    @Published var baseURLText: String
    @Published var tokenText: String

    init() {
        let credentials = KeychainCredentialStore()
        let api = APIClient(store: credentials)
        self.credentials = credentials
        self.cache = CacheManager()
        self.store = VideoStore(api: api)
        self.baseURLText = credentials.baseURL?.absoluteString ?? ""
        self.tokenText = credentials.token ?? ""
    }

    func saveSettings() {
        credentials.baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespaces))
        credentials.token = tokenText.isEmpty ? nil : tokenText
    }

    /// Absolute stream/download URL for a video's `streamPath`.
    func streamURL(for video: Video) -> URL? {
        guard let base = credentials.baseURL else { return nil }
        return base.appendingPathComponent(video.streamPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
```

- [x] **Step 5: Create `SettingsView.swift`**

```swift
// ios/PatataTube/Sources/SettingsView.swift
import SwiftUI
import PatataTubeKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL (https://…)", text: $model.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Upload token", text: $model.tokenText)
                }
                Section {
                    Button("Cache all videos") {
                        Task {
                            for video in model.store.videos {
                                if let url = model.streamURL(for: video) {
                                    try? await model.cache.download(id: video.id, from: url)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.saveSettings(); dismiss() }
                }
            }
        }
    }
}
```

- [x] **Step 6: Create `PatataTubeApp.swift`**

```swift
// ios/PatataTube/Sources/PatataTubeApp.swift
import SwiftUI

@main
struct PatataTubeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
        }
    }
}

// Temporary placeholder replaced in Task 9.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Text("PatataTube").font(.largeTitle)
            Text(model.credentials.baseURL?.absoluteString ?? "No server configured")
                .foregroundStyle(.secondary)
        }
    }
}
```

- [x] **Step 7: Generate the project and build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 8: Commit**

```bash
git add ios/PatataTube/project.yml ios/PatataTube/Sources ios/.gitignore
git commit -m "feat(ios): scaffold PatataTube app with settings + app model"
```

---

### Task 9: `VideoGridView` — grid, filter tabs, classify/reorder/download actions

**Files:**
- Create: `ios/PatataTube/Sources/VideoGridView.swift`
- Create: `ios/PatataTube/Sources/VideoCell.swift`
- Modify: `ios/PatataTube/Sources/PatataTubeApp.swift` (replace `RootView` body with `VideoGridView`)

**Interfaces:**
- Consumes: `AppModel`, `VideoStore`, `CacheManager`, `Video` (`PatataTubeKit`).
- Produces: `VideoGridView` (grid + classification filter tabs + toolbar buttons for Settings/Upload) and `VideoCell` (thumbnail, download button, reorder/classify menu). Verified by build + manual run.

- [x] **Step 1: Create `VideoCell.swift`**

```swift
// ios/PatataTube/Sources/VideoCell.swift
import SwiftUI
import PatataTubeKit

struct VideoCell: View {
    let video: Video
    let cacheState: CacheState
    let classifications: [String]
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onClassify: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                ZStack {
                    Rectangle().fill(.secondary.opacity(0.2))
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                    if let preview = video.previewUrl, let url = URL(string: preview) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { ProgressView() }
                        .clipped()
                    }
                    if video.status != "completed" {
                        Text(video.status).font(.caption).padding(4)
                            .background(.thinMaterial).cornerRadius(4)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)

            Text(video.title ?? video.url).font(.subheadline).lineLimit(1)

            HStack {
                downloadButton
                Spacer()
                Menu {
                    Button("Move up") { onMoveUp() }
                    Button("Move down") { onMoveDown() }
                    Divider()
                    ForEach(classifications, id: \.self) { c in
                        Button(c) { onClassify(c) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(12)
    }

    @ViewBuilder private var downloadButton: some View {
        switch cacheState {
        case .cached:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let p):
            ProgressView(value: p)
        case .notCached:
            Button(action: onDownload) { Image(systemName: "arrow.down.circle") }
        }
    }
}
```

- [x] **Step 2: Create `VideoGridView.swift`**

```swift
// ios/PatataTube/Sources/VideoGridView.swift
import SwiftUI
import PatataTubeKit

struct VideoGridView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: VideoStore

    @State private var classifications: [String] = ["children", "adults", "education", "entertainment"]
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var playing: Video?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                filterTabs
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.videos) { video in
                        VideoCell(
                            video: video,
                            cacheState: model.cache.state(for: video.id),
                            classifications: classifications,
                            onPlay: { playing = video },
                            onDownload: { download(video) },
                            onMoveUp: { Task { await store.move(id: video.id, direction: "up") } },
                            onMoveDown: { Task { await store.move(id: video.id, direction: "down") } },
                            onClassify: { c in Task { await store.classify(id: video.id, to: c) } }
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("PatataTube")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUpload = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await store.load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showUpload) { UploadView() }
            .fullScreenCover(item: $playing) { video in
                VideoPlayerView(video: video)
            }
            .task { await initialLoad() }
            .overlay { if let error = store.errorText { errorBanner(error) } }
        }
    }

    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                tab(title: "all", value: nil)
                ForEach(classifications, id: \.self) { c in tab(title: c, value: c) }
            }
            .padding(.horizontal)
        }
    }

    private func tab(title: String, value: String?) -> some View {
        Button(title) {
            store.filter = value
            Task { await store.load() }
        }
        .buttonStyle(.borderedProminent)
        .tint(store.filter == value ? .accentColor : .gray)
    }

    private func initialLoad() async {
        let api = APIClient(store: model.credentials)
        if let list = try? await api.classifications() { classifications = list }
        await store.load()
    }

    private func download(_ video: Video) {
        guard let url = model.streamURL(for: video) else { return }
        Task { try? await model.cache.download(id: video.id, from: url) }
    }

    private func errorBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.caption).padding()
                .background(.red.opacity(0.85)).foregroundStyle(.white).cornerRadius(8)
                .padding()
        }
    }
}
```

- [x] **Step 3: Replace `RootView` in `PatataTubeApp.swift`**

Replace the temporary `RootView` struct with:

```swift
struct RootView: View {
    var body: some View { VideoGridView() }
}
```

- [x] **Step 4: Regenerate + build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS' build
```

Expected: `** BUILD SUCCEEDED **` (references `UploadView`/`VideoPlayerView` from Task 10 — if building this task before Task 10, temporarily stub them; otherwise implement Task 10 first then build). To keep tasks independently buildable, add these one-line stubs now and delete them in Task 10:

```swift
// ios/PatataTube/Sources/Stubs.swift  (temporary — removed in Task 10)
import SwiftUI
import PatataTubeKit
struct UploadView: View { var body: some View { Text("Upload") } }
struct VideoPlayerView: View { let video: Video; var body: some View { Text(video.title ?? "") } }
```

- [x] **Step 5: Commit**

```bash
git add ios/PatataTube/Sources
git commit -m "feat(ios): add video grid with filter tabs, classify, reorder, download"
```

---

### Task 10: `VideoPlayerView` (fullscreen, exit-on-end) + `UploadView`

**Files:**
- Create: `ios/PatataTube/Sources/VideoPlayerView.swift`
- Create: `ios/PatataTube/Sources/UploadView.swift`
- Delete: `ios/PatataTube/Sources/Stubs.swift`

**Interfaces:**
- Consumes: `AppModel`, `VideoStore`, `CacheManager`, `Video`.
- Produces:
  - `VideoPlayerView` — `AVPlayer` fullscreen; plays local cached file when `CacheManager.state(for:) == .cached`, else streams from `streamURL`; auto-dismisses on playback end (parity: "exit fullscreen when video ends").
  - `UploadView` — paste URL → `store.upload(url:)` → dismiss.

- [x] **Step 1: Delete the temporary stubs**

```bash
rm ios/PatataTube/Sources/Stubs.swift
```

- [x] **Step 2: Create `VideoPlayerView.swift`**

```swift
// ios/PatataTube/Sources/VideoPlayerView.swift
import SwiftUI
import AVKit
import PatataTubeKit

struct VideoPlayerView: View {
    let video: Video
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32)).foregroundStyle(.white.opacity(0.8))
                    }.padding()
                }
                Spacer()
            }
        }
        .task { setup() }
        .onDisappear { player?.pause() }
    }

    private func setup() {
        let url: URL?
        if model.cache.state(for: video.id) == .cached {
            url = model.cache.localURL(for: video.id)
        } else {
            url = model.streamURL(for: video)
        }
        guard let url else { return }
        let player = AVPlayer(url: url)
        self.player = player
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in dismiss() }
    }
}
```

- [x] **Step 3: Create `UploadView.swift`**

```swift
// ios/PatataTube/Sources/UploadView.swift
import SwiftUI
import PatataTubeKit

struct UploadView: View {
    @EnvironmentObject var store: VideoStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Video URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            .navigationTitle("Add Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        submitting = true
                        Task {
                            await store.upload(url: urlText.trimmingCharacters(in: .whitespaces))
                            submitting = false
                            dismiss()
                        }
                    }
                    .disabled(urlText.isEmpty || submitting)
                }
            }
        }
    }
}
```

- [x] **Step 4: Regenerate + build**

```bash
cd ios/PatataTube && xcodegen generate
xcodebuild -project PatataTube.xcodeproj -scheme PatataTube \
  -destination 'generic/platform=iOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 5: Manual verification (simulator)**

Run: `xcodebuild -project PatataTube.xcodeproj -scheme PatataTube -destination 'platform=iOS Simulator,name=iPad Pro 11-inch' build` (or launch via Xcode). Then, against a running server (`./serve`), verify the feature-parity checklist:
- Grid shows thumbnails; filter tabs switch classification.
- Tap a video → fullscreen `AVPlayer`; playback to end auto-dismisses.
- Reorder up/down reflows the grid; classify via menu moves the video.
- `+` → paste URL → the list refetches after upload.
- Download button on a cell → after completion, replay works with the server stopped (offline).

- [x] **Step 6: Commit**

```bash
git add ios/PatataTube/Sources
git rm ios/PatataTube/Sources/Stubs.swift
git commit -m "feat(ios): add fullscreen player (exit-on-end) and upload view"
```

---

### Task 11: Docs — mark iOS plan complete

**Files:**
- Modify: `docs/superpowers/specs/2026-07-02-ipad-native-app-design.md`
- Modify: `docs/superpowers/plans/2026-07-02-ios-swiftui-app.md` (this file)

**Interfaces:**
- Consumes: nothing.
- Produces: updated progress/status so a future session sees the app as done.

- [x] **Step 1: Update the spec progress section**

In `docs/superpowers/specs/2026-07-02-ipad-native-app-design.md`, change the `### iOS SwiftUI App — NOT STARTED` block to `— COMPLETE (2026-07-02)` with a one-line summary of the `ios/PatataTubeKit` + `ios/PatataTube` structure, and tick every box in the "Feature parity checklist".

- [x] **Step 2: Mark this plan complete**

Add a `> **STATUS: COMPLETE**` line under this plan's header with the commit range.

- [x] **Step 3: Commit**

```bash
git add docs/superpowers
git commit -m "docs: mark iOS SwiftUI app plan complete"
```

---

## Self-Review

**Spec coverage** (spec §"Feature parity checklist" and §"App architecture"):
- Grid + preview thumbnails → Task 9 (`VideoCell` `AsyncImage`). ✓
- Classification filter tabs → Task 9 (`filterTabs`, synced via `GET /api/classifications` in Task 9 Step 2). ✓
- Fullscreen playback + exit-on-end → Task 10 (`AVPlayerItemDidPlayToEndTime` → `dismiss`). ✓
- Reorder up/down → Tasks 5 (`APIClient.move`) + 7 (`VideoStore.move`) + 9 (menu). ✓
- Set classification → Tasks 5 + 7 (optimistic) + 9. ✓
- Upload by URL (Bearer) → Tasks 5 (`upload`) + 10 (`UploadView`). ✓
- Offline playback of cached videos → Tasks 6 (`CacheManager`) + 10 (local-file preference). ✓
- `APIClient`/`VideoStore`/`CacheManager`/`KeychainStore`/Views layers → Tasks 3–10. ✓
- Unit tests (APIClient decode, CacheManager path/state, VideoStore filter/optimism, Swift Testing) → Tasks 2,4,5,6,7. ✓
- Xcode project in `ios/` → Tasks 1 (`PatataTubeKit`) + 8 (`PatataTube` app). ✓
- Out-of-scope (LRU eviction, live updates, iPhone tuning) → correctly omitted. ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N". Every code step shows full code; every command shows expected output. The intentional `fatalError("implemented in Task 5")` stubs in Task 4 are explicitly replaced in Task 5 Step 3 — not a hidden placeholder. The Task 9 temporary `Stubs.swift` is explicitly created then removed in Task 10.

**Type consistency:** `Video` fields (`previewUrl`, `sourceKey`, `errorMsg`, `streamPath`) consistent across Tasks 2/4/7/9/10. `VideoAPI` five signatures identical in Tasks 4/5/7 (`FakeAPI`) . `CacheState` (`.notCached/.downloading(Double)/.cached`) consistent Tasks 6/9/10. `CredentialStore` (`baseURL`, `token`) consistent Tasks 3/4/8. `VideoStore` API (`load/classify(id:to:)/move(id:direction:)/upload(url:)`) consistent Tasks 7/9/10.
