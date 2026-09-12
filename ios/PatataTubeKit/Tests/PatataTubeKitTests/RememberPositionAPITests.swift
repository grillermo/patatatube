import Testing
import Foundation
@testable import PatataTubeKit

// Nested in the one serialized APIClientTests suite because MockURLProtocol's
// handler is global to the test process.
extension APIClientTests {
    struct RememberPositionTests {
        @Test func videoDecodesRememberPosition() throws {
            let json = """
            {"id": 1, "url": "u", "group_id": 3, "plex_kind": null, "status": "done",
             "stream_path": "/videos/1/stream", "remember_position": true}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.rememberPosition)
        }

        @Test func videoRememberPositionDefaultsToFalseWhenMissing() throws {
            // An offline VideoListCache written before this feature shipped has
            // no such key; it must still decode rather than poisoning the list.
            let json = """
            {"id": 1, "url": "u", "group_id": 3, "plex_kind": null, "status": "done",
             "stream_path": "/videos/1/stream"}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let video = try decoder.decode(Video.self, from: json)
            #expect(video.rememberPosition == false)
        }

        @Test func withRememberPositionFlipsOnlyThatField() {
            let video = Video(
                id: 7, url: "u", title: "t", platform: nil, sourceKey: nil,
                previewUrl: nil, groupID: 3, plexKind: nil, position: nil,
                status: "done", errorMsg: nil, streamPath: "/videos/7/stream",
                subtitleLang: "es", resumeSecs: 91.5
            )
            let flipped = video.withRememberPosition(true)
            #expect(flipped.rememberPosition)
            #expect(flipped.resumeSecs == 91.5)
            #expect(flipped.subtitleLang == "es")
            #expect(flipped.id == 7)
        }

        @Test func theOtherCopyHelpersCarryRememberPositionThrough() {
            // Every `with…` helper rebuilds Video field by field, so a new
            // stored property is silently dropped unless each one passes it.
            let video = Video(
                id: 7, url: "u", title: "t", platform: nil, sourceKey: nil,
                previewUrl: nil, groupID: 3, plexKind: nil, position: nil,
                status: "done", errorMsg: nil, streamPath: "/videos/7/stream",
                rememberPosition: true
            )
            #expect(video.withGroupID(9).rememberPosition)
            #expect(video.withAudioLang("spa").rememberPosition)
            #expect(video.withSubtitleLang("es").rememberPosition)
            #expect(video.withChosenVersion(nil).rememberPosition)
        }

        @Test func setRememberPositionPostsTheFlag() async throws {
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/api/videos/12/remember-position")
                let json = try JSONSerialization.jsonObject(
                    with: request.httpBodyData()
                ) as? [String: Bool]
                #expect(json?["on"] == true)
                return (jsonResponse(request.url!, status: 200), Data("{\"ok\": true}".utf8))
            }

            let ok = try await makeClient(statusToken: "tok")
                .setRememberPosition(id: 12, on: true)
            #expect(ok)
        }

        @Test func setRememberPositionPostsFalse() async throws {
            MockURLProtocol.handler = { request in
                let json = try JSONSerialization.jsonObject(
                    with: request.httpBodyData()
                ) as? [String: Bool]
                #expect(json?["on"] == false)
                return (jsonResponse(request.url!, status: 200), Data("{\"ok\": true}".utf8))
            }

            let ok = try await makeClient(statusToken: "tok")
                .setRememberPosition(id: 12, on: false)
            #expect(ok)
        }

        @Test func setRememberPositionThrowsOnBadStatus() async {
            MockURLProtocol.handler = { request in
                (jsonResponse(request.url!, status: 404), Data())
            }
            await #expect(throws: APIError.badStatus(404)) {
                _ = try await makeClient(statusToken: "tok")
                    .setRememberPosition(id: 12, on: true)
            }
        }
    }
}
