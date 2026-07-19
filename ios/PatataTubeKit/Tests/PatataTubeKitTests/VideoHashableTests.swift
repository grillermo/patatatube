import XCTest
@testable import PatataTubeKit

final class VideoHashableTests: XCTestCase {
    func testVideoIsHashable() {
        let video = Video(id: 1, url: "https://example.com", title: "A Movie",
                          platform: nil, sourceKey: nil, previewUrl: nil,
                          classification: "movies", position: nil, status: "done",
                          errorMsg: nil, streamPath: "/videos/1/stream",
                          versions: [VideoVersion(id: 1, label: "1080p", status: "done", isChosen: true)],
                          subtitleTracks: [SubtitleTrack(language: "en", name: "English", default: true, forced: false)])
        XCTAssertEqual(Set([video, video]).count, 1)
    }
}
