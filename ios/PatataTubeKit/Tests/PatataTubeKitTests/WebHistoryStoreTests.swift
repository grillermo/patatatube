import Foundation
import Testing
@testable import PatataTubeKit

/// Each test gets its own defaults suite so runs never bleed into each other
/// or into the developer's real `standard` defaults.
private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func url(_ s: String) -> URL { URL(string: s)! }

struct WebHistoryStoreTests {
    @Test func startsEmpty() {
        let store = WebHistoryStore(defaults: makeDefaults())
        #expect(store.entries.isEmpty)
        #expect(store.lastURL == nil)
    }

    @Test func recordsNewestFirst() {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://a.example.com/one"))
        store.record(url("https://b.example.com/two"))

        #expect(store.entries.map(\.url) == ["https://b.example.com/two",
                                             "https://a.example.com/one"])
        #expect(store.lastURL == url("https://b.example.com/two"))
    }

    @Test func revisitingMovesToFrontWithoutDuplicating() {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://a.example.com/one"))
        store.record(url("https://b.example.com/two"))
        store.record(url("https://a.example.com/one"))

        #expect(store.entries.map(\.url) == ["https://a.example.com/one",
                                             "https://b.example.com/two"])
        #expect(store.entries.count == 2)
    }

    @Test func evictsTheOldestBeyondTheLimit() {
        let store = WebHistoryStore(defaults: makeDefaults(), limit: 3)
        for i in 1...5 { store.record(url("https://example.com/\(i)")) }

        #expect(store.entries.map(\.url) == ["https://example.com/5",
                                             "https://example.com/4",
                                             "https://example.com/3"])
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        WebHistoryStore(defaults: defaults).record(url("https://a.example.com/one"))

        let reopened = WebHistoryStore(defaults: defaults)
        #expect(reopened.lastURL == url("https://a.example.com/one"))
    }

    @Test func treatsCorruptStorageAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "webBridgeHistory")

        let store = WebHistoryStore(defaults: defaults)
        #expect(store.entries.isEmpty)

        store.record(url("https://a.example.com/one"))
        #expect(store.entries.map(\.url) == ["https://a.example.com/one"])
    }
}

struct WebHistorySearchTests {
    private func seeded() -> WebHistoryStore {
        let store = WebHistoryStore(defaults: makeDefaults())
        store.record(url("https://awh.chiq.me/live"))
        store.record(url("https://example.com/videos/cats"))
        store.record(url("https://awh.chiq.me/archive"))
        return store   // newest first: archive, cats, live
    }

    @Test func blankQueryReturnsEverythingNewestFirst() {
        #expect(seeded().search("   ").map(\.url) == ["https://awh.chiq.me/archive",
                                                      "https://example.com/videos/cats",
                                                      "https://awh.chiq.me/live"])
    }

    @Test func matchesASingleSubstring() {
        #expect(seeded().search("cats").map(\.url) == ["https://example.com/videos/cats"])
    }

    @Test func spacesActAsWildcards() {
        #expect(seeded().search("awh live").map(\.url) == ["https://awh.chiq.me/live"])
    }

    @Test func tokensMustAppearInOrder() {
        #expect(seeded().search("live awh").isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(seeded().search("AWH ARCHIVE").map(\.url) == ["https://awh.chiq.me/archive"])
    }

    @Test func multipleMatchesStayNewestFirst() {
        #expect(seeded().search("awh").map(\.url) == ["https://awh.chiq.me/archive",
                                                      "https://awh.chiq.me/live"])
    }

    @Test func noMatchesIsEmpty() {
        #expect(seeded().search("nonesuch").isEmpty)
    }
}
