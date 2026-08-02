import Testing
import Foundation
@testable import PatataTubeKit

// Nested in the one serialized APIClientTests suite because MockURLProtocol's
// handler is global to the test process.
extension APIClientTests {
    struct ResumePositionTests {
        @Test func videoDecodesResumeSecs() throws {
            let json = """
            {"id": 1, "url": "u", "classification": "movies", "status": "done",
             "stream_path": "/videos/1/stream", "resume_secs": 91.5}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.resumeSecs == 91.5)
        }

        @Test func videoResumeSecsDefaultsToZeroWhenMissing() throws {
            let json = """
            {"id": 1, "url": "u", "classification": "movies", "status": "done",
             "stream_path": "/videos/1/stream"}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.resumeSecs == 0)
        }

        @Test func savePositionPostsSeconds() async throws {
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/api/videos/12/position")
                let json = try JSONSerialization.jsonObject(
                    with: request.httpBodyData()
                ) as? [String: Double]
                #expect(json?["secs"] == 91.5)
                return (jsonResponse(request.url!, status: 204), Data())
            }

            try await makeClient(statusToken: "tok").savePosition(id: 12, secs: 91.5)
        }

        @Test func savePositionThrowsOnBadStatus() async {
            MockURLProtocol.handler = { request in
                (jsonResponse(request.url!, status: 500), Data())
            }
            await #expect(throws: APIError.badStatus(500)) {
                try await makeClient(statusToken: "tok").savePosition(id: 12, secs: 10)
            }
        }

        @Test func boundSaveRefusesAChangedDestinationBeforeRequest() async {
            let credentials = InMemoryCredentialStore(
                baseURL: URL(string: "https://server-a.test")!, token: "tok"
            )
            let client = APIClient(store: credentials, session: mockSession())
            let serverA = ResumePositionStore.normalizedServerIdentity(credentials.baseURL)
            credentials.baseURL = URL(string: "https://server-b.test")!
            MockURLProtocol.handler = { request in
                Issue.record("unexpected request to \(request.url?.absoluteString ?? "-")")
                return (jsonResponse(request.url!, status: 204), Data())
            }

            await #expect(throws: APIError.serverChanged) {
                try await client.savePosition(
                    id: 12,
                    secs: 10,
                    destinationServerIdentity: serverA
                )
            }
        }

        private func makeClient(statusToken token: String) -> APIClient {
            let store = InMemoryCredentialStore(
                baseURL: URL(string: "https://srv.test")!, token: token
            )
            return APIClient(store: store, session: mockSession())
        }
    }
}
