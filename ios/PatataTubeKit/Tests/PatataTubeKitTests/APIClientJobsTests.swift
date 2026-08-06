import Testing
import Foundation
@testable import PatataTubeKit

// Nested inside APIClientTests (declared in APIClientReadTests.swift) so it inherits that
// suite's `.serialized` trait — MockURLProtocol.handler is a global static shared by every
// API client test, and a sibling top-level suite would otherwise run concurrently with it
// and race on the handler (see APIClientLibraryTests.swift for the same reasoning).
extension APIClientTests {
    struct JobsTests {
        private func makeClient() -> APIClient {
            let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: "tok")
            return APIClient(store: store, session: mockSession())
        }

        @Test func fetchesRunningAndQueuedJobs() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/jobs")
                let body = """
                {"running":[{"id":41,"kind":"convert","video_id":812,"version_id":3,
                             "priority":100,"progress":0.47,"title":"Blade Runner",
                             "show_title":null}],
                 "queued":[{"id":42,"kind":"hls","video_id":813,"version_id":4,
                            "priority":0,"progress":null,"title":"Dune","show_title":null}],
                 "queued_total":203}
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let snapshot = try await makeClient().jobs()
            #expect(snapshot.running.count == 1)
            #expect(snapshot.running[0].videoID == 812)
            #expect(snapshot.running[0].progress == 0.47)
            #expect(snapshot.queued[0].progress == nil)
            #expect(snapshot.queued[0].title == "Dune")
            #expect(snapshot.queuedTotal == 203)
        }

        @Test func decodesAnEmptySnapshot() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"running":[],"queued":[],"queued_total":0}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let snapshot = try await makeClient().jobs()
            #expect(snapshot == .empty)
        }
    }
}
