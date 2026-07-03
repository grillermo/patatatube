import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient(token: String? = "tok") -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: token)
    return APIClient(store: store, session: mockSession())
}

// All API client tests share MockURLProtocol.handler (a global static), so the entire
// parent suite is serialized to prevent cross-suite interference.
@Suite(.serialized)
struct APIClientTests {

    // MARK: - Read tests

    struct ReadTests {
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
    }

    // MARK: - Write tests

    struct WriteTests {
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
    }
}
