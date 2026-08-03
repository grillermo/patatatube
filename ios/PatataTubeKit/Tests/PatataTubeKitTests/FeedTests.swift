import XCTest
@testable import PatataTubeKit

final class FeedTests: XCTestCase {
    func testQueryItemsForEachCase() {
        XCTAssertEqual(Feed.all.queryItems, [])
        XCTAssertEqual(Feed.group(id: 3).queryItems, [URLQueryItem(name: "group_id", value: "3")])
        XCTAssertEqual(Feed.plex(.tv).queryItems, [URLQueryItem(name: "plex_kind", value: "tv")])
    }

    func testStorageKeysRoundTrip() {
        for feed in [Feed.all, .group(id: 42), .plex(.movies)] {
            XCTAssertEqual(Feed(storageKey: feed.storageKey), feed)
        }
    }

    func testStorageKeySpellings() {
        XCTAssertEqual(Feed.all.storageKey, "all")
        XCTAssertEqual(Feed.group(id: 3).storageKey, "group:3")
        XCTAssertEqual(Feed.plex(.tv).storageKey, "plex:tv")
    }

    func testStorageKeyRejectsGarbage() {
        XCTAssertNil(Feed(storageKey: "group:notanumber"))
        XCTAssertNil(Feed(storageKey: "plex:podcasts"))
        XCTAssertNil(Feed(storageKey: ""))
    }

    func testCodableRoundTrip() throws {
        let feed = Feed.group(id: 7)
        let data = try JSONEncoder().encode(feed)
        XCTAssertEqual(try JSONDecoder().decode(Feed.self, from: data), feed)
    }

    func testVideoGroupDecodesServerJSON() throws {
        let json = #"{"id":2,"name":"adults","label":"Adults","emoji":"🍷","position":1}"#
        let group = try JSONDecoder().decode(VideoGroup.self, from: Data(json.utf8))
        XCTAssertEqual(group.id, 2)
        XCTAssertEqual(group.label, "Adults")
        XCTAssertEqual(group.emoji, "🍷")
    }

    func testVideoGroupDecodesANullEmoji() throws {
        let json = #"{"id":1,"name":"children","label":"Children","emoji":null,"position":0}"#
        XCTAssertNil(try JSONDecoder().decode(VideoGroup.self, from: Data(json.utf8)).emoji)
    }
}
