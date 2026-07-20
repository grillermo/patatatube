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

        @Test func decodesHlsAndSubtitleMetadata() async throws {
            MockURLProtocol.handler = { req in
                let body = """
                [{"id":1,"url":"u","title":"t","platform":null,"source_key":null,
                  "preview_url":null,"classification":"children","position":1,
                  "status":"done","error_msg":null,"stream_path":"/videos/1/stream",
                  "hls_path":"/videos/1/hls/master.m3u8",
                  "subtitle_tracks":[{"language":"en","name":"English","default":true,"forced":false}]}]
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let videos = try await makeClient().videos(classification: nil)
            #expect(videos[0].hlsPath == "/videos/1/hls/master.m3u8")
            #expect(videos[0].subtitleTracks.count == 1)
            #expect(videos[0].subtitleTracks[0].language == "en")
            #expect(videos[0].subtitleTracks[0].name == "English")
            #expect(videos[0].subtitleTracks[0].default == true)
        }

        @Test func decodesVideoWithoutHlsFields() async throws {
            MockURLProtocol.handler = { req in
                let body = """
                [{"id":2,"url":"u","title":null,"platform":null,"source_key":null,
                  "preview_url":null,"classification":"children","position":1,
                  "status":"done","error_msg":null,"stream_path":"/videos/2/stream"}]
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let videos = try await makeClient().videos(classification: nil)
            #expect(videos[0].hlsPath == nil)
            #expect(videos[0].subtitleTracks.isEmpty)
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

        @Test func chooseAudioSendsLanguage() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/videos/3/audio")
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: String]
                #expect(json["lang"] == "es")
                return (jsonResponse(req.url!), #"{"ok":true}"#.data(using: .utf8)!)
            }
            #expect(try await makeClient().chooseAudio(id: 3, lang: "es"))
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
                _ = try await makeClient(token: nil).classify(id: 1, classification: "children")
            }
        }
    }
}
