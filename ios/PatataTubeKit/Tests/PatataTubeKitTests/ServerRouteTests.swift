import Testing
import Foundation
@testable import PatataTubeKit

struct ServerRoutingTests {
    private let lan = URL(string: "http://192.168.1.1:3050")!
    private let remote = URL(string: "https://videos.chiq.me")!

    @Test func rebasesPathAndQueryOntoRemote() {
        let url = URL(string: "http://192.168.1.1:3050/api/videos?group=3")!
        #expect(ServerRouting.rebase(url, from: lan, to: remote)?.absoluteString
            == "https://videos.chiq.me/api/videos?group=3")
    }

    @Test func doesNotRebaseAnotherHost() {
        let url = URL(string: "http://192.168.1.10:3050/api/videos")!
        #expect(ServerRouting.rebase(url, from: lan, to: remote) == nil)
    }

    @Test func connectFailuresAlwaysRetry() {
        #expect(ServerRouting.isRetryableConnectFailure(URLError(.cannotConnectToHost), idempotent: false))
    }

    @Test func timeoutsRetryOnlyWhenIdempotent() {
        #expect(ServerRouting.isRetryableConnectFailure(URLError(.timedOut), idempotent: true))
        #expect(!ServerRouting.isRetryableConnectFailure(URLError(.timedOut), idempotent: false))
    }

    @Test func routedStoreReadsLANOnlyWhileActive() {
        let defaults = UserDefaults(suiteName: "ServerRoutingTests-\(UUID())")!
        let store = RoutedCredentialStore(
            inner: InMemoryCredentialStore(baseURL: remote, token: "t"), defaults: defaults
        )
        #expect(store.baseURL == remote)
        store.use(lan: lan)
        #expect(store.baseURL == lan)
        #expect(store.identityURL == remote)
        store.lanFailed(from: lan)
        #expect(store.baseURL == remote)
        #expect(store.route == .remote)
    }

    @Test func blankLANTurnsTheRouteOff() {
        let defaults = UserDefaults(suiteName: "ServerRoutingTests-\(UUID())")!
        let store = RoutedCredentialStore(inner: InMemoryCredentialStore(), defaults: defaults)
        #expect(store.lanURL?.absoluteString == ServerRouting.defaultLANURL)
        store.lanURLText = "  "
        #expect(store.lanURL == nil)
    }
}

// Nested in APIClientTests for its `.serialized` trait: MockURLProtocol.handler
// is shared by every API client test.
extension APIClientTests {
    struct LANFallbackTests {
        private let lan = URL(string: "http://192.168.1.1:3050")!
        private let remote = URL(string: "https://srv.test")!

        private func makeStore() -> RoutedCredentialStore {
            let defaults = UserDefaults(suiteName: "LANFallbackTests-\(UUID())")!
            let store = RoutedCredentialStore(
                inner: InMemoryCredentialStore(baseURL: remote, token: "tok"), defaults: defaults
            )
            store.use(lan: lan)
            return store
        }

        @Test func getRetriesThroughRemoteWhenLANRefuses() async throws {
            let store = makeStore()
            nonisolated(unsafe) var hosts: [String] = []
            MockURLProtocol.handler = { req in
                hosts.append(req.url!.host!)
                if req.url!.host == "192.168.1.1" { throw URLError(.cannotConnectToHost) }
                return (jsonResponse(req.url!), #"{"running":[],"queued":[],"queued_total":0}"#.data(using: .utf8)!)
            }
            _ = try await APIClient(store: store, session: mockSession()).jobs()
            #expect(hosts == ["192.168.1.1", "srv.test"])
            #expect(store.route == .remote)
        }

        @Test func postIsNotResentAfterATimeout() async throws {
            let store = makeStore()
            nonisolated(unsafe) var calls = 0
            MockURLProtocol.handler = { _ in
                calls += 1
                throw URLError(.timedOut)
            }
            await #expect(throws: URLError.self) {
                _ = try await APIClient(store: store, session: mockSession()).markPlayed(id: 1)
            }
            #expect(calls == 1)
        }

        @Test func positionsKeepTheRemoteIdentityOnLAN() async throws {
            let store = makeStore()
            MockURLProtocol.handler = { req in (jsonResponse(req.url!, status: 204), Data()) }
            try await APIClient(store: store, session: mockSession()).savePosition(
                id: 1, secs: 30,
                destinationServerIdentity: ResumePositionStore.normalizedServerIdentity(remote)
            )
        }
    }
}
