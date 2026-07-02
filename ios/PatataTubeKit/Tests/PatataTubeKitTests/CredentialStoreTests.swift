import Testing
import Foundation
@testable import PatataTubeKit

@Test func inMemoryStoreRoundTrips() {
    let store: CredentialStore = InMemoryCredentialStore()
    #expect(store.baseURL == nil)
    #expect(store.token == nil)

    store.baseURL = URL(string: "https://example.test")
    store.token = "secret"
    #expect(store.baseURL?.absoluteString == "https://example.test")
    #expect(store.token == "secret")
}
