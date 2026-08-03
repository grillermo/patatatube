import XCTest
@testable import PatataTubeKit

final class MediaTabTests: XCTestCase {
    func testTabFeeds() {
        XCTAssertNil(MediaTab.videos.feed)
        XCTAssertEqual(MediaTab.tv.feed, .plex(.tv))
        XCTAssertEqual(MediaTab.movies.feed, .plex(.movies))
    }

}
