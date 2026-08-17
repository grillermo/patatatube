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
                  "preview_url":"p","group_id":1,"plex_kind":null,"position":1,
                  "status":"completed","error_msg":null,"stream_path":"/videos/1/stream"}]
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let videos = try await makeClient().videos(feed: .all)
            #expect(videos.count == 1)
            #expect(videos[0].previewUrl == "p")
        }

        @Test func videosSendsTheGroupIDQuery() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.query == "group_id=3")
                return (jsonResponse(req.url!), "[]".data(using: .utf8)!)
            }
            let videos = try await makeClient().videos(feed: .group(id: 3))
            #expect(videos.isEmpty)
        }

        @Test func videosSendsThePlexKindQuery() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.query == "plex_kind=movies")
                return (jsonResponse(req.url!), "[]".data(using: .utf8)!)
            }
            _ = try await makeClient().videos(feed: .plex(.movies))
        }

        @Test func videosSendsNoQueryForAll() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.query == nil)
                return (jsonResponse(req.url!), "[]".data(using: .utf8)!)
            }
            _ = try await makeClient().videos(feed: .all)
        }

        @Test func groupsDecodesAndSortsByPosition() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"groups":[{"id":2,"name":"adults","label":"Adults","emoji":null,"position":1},{"id":1,"name":"children","label":"Children","emoji":"🧒","position":0}]}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let groups = try await makeClient().groups()
            #expect(groups.map(\.name) == ["children", "adults"])
            #expect(groups[0].emoji == "🧒")
        }

        @Test func groupsDecodesDisplayTitles() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"groups":[{"id":1,"name":"children","label":"Children","emoji":null,"position":0,"display_titles":true}]}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            #expect(try await makeClient().groups()[0].displayTitles)
        }

        /// A server that predates the column — and the UserDefaults mirror
        /// written by an older build — both omit the key.
        @Test func groupsDefaultDisplayTitlesToOffWhenTheKeyIsMissing() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"groups":[{"id":1,"name":"children","label":"Children","emoji":null,"position":0}]}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            #expect(try await makeClient().groups()[0].displayTitles == false)
        }

        @Test func groupsDoesNotRequireOrSendAToken() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/groups")
                #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
                return (jsonResponse(req.url!), #"{"groups":[]}"#.data(using: .utf8)!)
            }

            #expect(try await makeClient(token: nil).groups().isEmpty)
        }

        @Test func decodesHlsAndSubtitleMetadata() async throws {
            MockURLProtocol.handler = { req in
                let body = """
                [{"id":1,"url":"u","title":"t","platform":null,"source_key":null,
                  "preview_url":null,"group_id":1,"plex_kind":null,"position":1,
                  "status":"done","error_msg":null,"stream_path":"/videos/1/stream",
                  "hls_path":"/videos/1/hls/master.m3u8",
                  "subtitle_lang":"en",
                  "subtitle_tracks":[{"language":"en","name":"English","default":true,"forced":false}]}]
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let videos = try await makeClient().videos(feed: .all)
            #expect(videos[0].hlsPath == "/videos/1/hls/master.m3u8")
            #expect(videos[0].subtitleTracks.count == 1)
            #expect(videos[0].subtitleTracks[0].language == "en")
            #expect(videos[0].subtitleTracks[0].name == "English")
            #expect(videos[0].subtitleTracks[0].default == true)
            #expect(videos[0].subtitleLang == "en")
        }

        @Test func decodesVideoWithoutHlsFields() async throws {
            MockURLProtocol.handler = { req in
                let body = """
                [{"id":2,"url":"u","title":null,"platform":null,"source_key":null,
                  "preview_url":null,"group_id":1,"plex_kind":null,"position":1,
                  "status":"done","error_msg":null,"stream_path":"/videos/2/stream"}]
                """.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            let videos = try await makeClient().videos(feed: .all)
            #expect(videos[0].hlsPath == nil)
            #expect(videos[0].subtitleTracks.isEmpty)
        }

        @Test func throwsOnBadStatus() async {
            MockURLProtocol.handler = { req in (jsonResponse(req.url!, status: 500), Data()) }
            await #expect(throws: APIError.badStatus(500)) {
                _ = try await makeClient().videos(feed: .all)
            }
        }

        @Test func throwsWhenBaseURLMissing() async {
            let store = InMemoryCredentialStore(baseURL: nil, token: "t")
            let client = APIClient(store: store, session: mockSession())
            await #expect(throws: APIError.notConfigured) {
                _ = try await client.videos(feed: .all)
            }
        }
    }

    // MARK: - Write tests

    struct WriteTests {
        @Test func updateGroupSendsAnExplicitNullToClearTheEmoji() async throws {
            MockURLProtocol.handler = { req in
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: Any]
                #expect(json.keys.contains("emoji"))
                #expect(json["emoji"] is NSNull)
                return (jsonResponse(req.url!), #"{"id":1,"name":"children","label":"Children","emoji":null,"position":0}"#.data(using: .utf8)!)
            }
            _ = try await makeClient().updateGroup(id: 1, label: nil, emoji: nil)
        }

        /// Must not go through `updateGroup`, which always sends `emoji` and
        /// would clear a group's cover as a side effect of this toggle.
        @Test func setDisplayTitlesSendsThatFieldAlone() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/groups/1")
                #expect(req.httpMethod == "PATCH")
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: Any]
                #expect(Array(json.keys) == ["display_titles"])
                #expect(json["display_titles"] as? Bool == true)
                return (jsonResponse(req.url!), #"{"id":1,"name":"children","label":"Children","emoji":"🧒","position":0,"display_titles":true}"#.data(using: .utf8)!)
            }
            let group = try await makeClient().setGroupDisplayTitles(id: 1, true)
            #expect(group.displayTitles)
            #expect(group.emoji == "🧒")
        }

        @Test func promotePostsTheKind() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/videos/5/promote")
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: String]
                #expect(json["kind"] == "tv")
                return (jsonResponse(req.url!), #"{"ok":true,"promoted":true}"#.data(using: .utf8)!)
            }
            #expect(try await makeClient().promote(id: 5, kind: .tv))
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
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: Any]
                #expect(json["url"] as? String == "https://youtu.be/xyz")
                #expect(json["group_id"] as? Int == 3)
                return (jsonResponse(req.url!, status: 202), #"{"id":42,"status":"queued"}"#.data(using: .utf8)!)
            }
            let id = try await makeClient().upload(url: "https://youtu.be/xyz", groupID: 3)
            #expect(id == 42)
        }

        @Test func writeThrowsWithoutToken() async {
            await #expect(throws: APIError.notConfigured) {
                _ = try await makeClient(token: nil).promote(id: 1, kind: .tv)
            }
        }
    }
}
