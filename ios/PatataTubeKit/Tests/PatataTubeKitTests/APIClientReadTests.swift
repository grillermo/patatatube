import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient() -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: "tok")
    return APIClient(store: store, session: mockSession())
}

// Tests are serialized because MockURLProtocol.handler is a shared static.
@Suite(.serialized)
struct APIClientReadTests {
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
