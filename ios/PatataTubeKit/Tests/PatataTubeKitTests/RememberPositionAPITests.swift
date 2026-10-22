import Testing
import Foundation
@testable import PatataTubeKit

private func makeClient() -> APIClient {
    let store = InMemoryCredentialStore(baseURL: URL(string: "https://srv.test")!, token: "tok")
    return APIClient(store: store, session: mockSession())
}

// Nested in the one serialized APIClientTests suite because MockURLProtocol's
// handler is global to the test process.
extension APIClientTests {
    struct RememberPositionTests {
        @Test func groupDecodesRememberPosition() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"groups":[{"id":1,"name":"children","label":"Children","emoji":null,"position":0,"remember_position":true}]}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            #expect(try await makeClient().groups()[0].rememberPosition)
        }

        @Test func groupRememberPositionDefaultsToOffWhenTheKeyIsMissing() async throws {
            MockURLProtocol.handler = { req in
                let body = #"{"groups":[{"id":1,"name":"children","label":"Children","emoji":null,"position":0}]}"#.data(using: .utf8)!
                return (jsonResponse(req.url!), body)
            }
            #expect(try await makeClient().groups()[0].rememberPosition == false)
        }

        @Test func setGroupRememberPositionSendsThatFieldAlone() async throws {
            MockURLProtocol.handler = { req in
                #expect(req.httpMethod == "PATCH")
                #expect(req.url?.path == "/api/groups/1")
                let json = try JSONSerialization.jsonObject(with: req.httpBodyData()) as! [String: Any]
                #expect(Array(json.keys) == ["remember_position"])
                #expect(json["remember_position"] as? Bool == true)
                return (jsonResponse(req.url!), #"{"id":1,"name":"children","label":"Children","emoji":"🧒","position":0,"remember_position":true}"#.data(using: .utf8)!)
            }
            let group = try await makeClient().setGroupRememberPosition(id: 1, true)
            #expect(group.rememberPosition)
            #expect(group.emoji == "🧒")
        }
    }
}
