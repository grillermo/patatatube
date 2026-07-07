import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient(token: String? = "secret") -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://example.test")!, token: token)
    return APIClient(store: store, session: mockSession())
}

// Nested inside APIClientTests (declared in APIClientReadTests.swift) so it inherits that
// suite's `.serialized` trait — MockURLProtocol.handler is a global static shared by every
// API client test, and a sibling top-level suite would otherwise run concurrently with it
// and race on the handler.
extension APIClientTests {
    struct LibraryTests {
        @Test func scanLibrary() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/library/scan")
                #expect(req.httpMethod == "POST")
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
                let body = #"{"added": 3, "updated": 1, "skipped": 2}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let result = try await makeClient().scanLibrary()
            #expect(result == ScanResult(added: 3, updated: 1, skipped: 2))
        }

        @Test func prepare() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/videos/7/prepare")
                return (jsonResponse(req.url!, status: 202), #"{"status": "converting"}"#.data(using: .utf8)!)
            }
            let status = try await makeClient().prepare(id: 7)
            #expect(status == "converting")
        }

        @Test func fetchSingleVideo() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/videos/7")
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
                let body = #"""
                {"id": 7, "url": "/x", "title": null, "platform": null,
                    "source_key": null, "preview_url": null, "classification": "tv",
                    "position": 1, "status": "done", "error_msg": null,
                    "stream_path": "/videos/7/stream", "source": "library"}
                """#
                return (jsonResponse(req.url!), body.data(using: .utf8)!)
            }
            let video = try await makeClient().video(id: 7)
            #expect(video.id == 7)
            #expect(video.status == "done")
        }

        @Test func imageDataRelativePathIsAuthed() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.absoluteString == "https://example.test/videos/7/preview?kind=show")
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
                return (jsonResponse(req.url!), Data([0xFF, 0xD8]))
            }
            let data = try await makeClient().imageData(path: "/videos/7/preview?kind=show")
            #expect(data == Data([0xFF, 0xD8]))
        }

        @Test func imageDataAbsoluteURLSkipsAuth() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.host == "i.ytimg.com")
                #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
                return (jsonResponse(req.url!), Data([0x01]))
            }
            _ = try await makeClient().imageData(path: "https://i.ytimg.com/vi/x/hqdefault.jpg")
        }
    }
}
