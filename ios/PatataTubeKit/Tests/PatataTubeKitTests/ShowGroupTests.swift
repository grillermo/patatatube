import XCTest
@testable import PatataTubeKit

final class ShowGroupTests: XCTestCase {
    private func episode(_ id: Int, show: String, season: Int, ep: Int) -> Video {
        Video(id: id, url: "/x", title: "E\(ep)", platform: nil, sourceKey: nil,
              previewUrl: nil, classification: "tv", position: id, status: "unconverted",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: show, season: season, episode: ep,
              summary: nil, showPreviewUrl: "/videos/\(id)/preview?kind=show")
    }

    func testGroupsAndSorts() {
        let videos = [
            episode(1, show: "The Bear", season: 2, ep: 1),
            episode(2, show: "Bluey", season: 1, ep: 3),
            episode(3, show: "The Bear", season: 1, ep: 2),
            episode(4, show: "The Bear", season: 1, ep: 1),
        ]
        let groups = ShowGroup.group(videos)
        XCTAssertEqual(groups.map(\.title), ["Bluey", "The Bear"])
        XCTAssertEqual(groups[1].episodes.map(\.id), [4, 3, 1])
        XCTAssertEqual(groups[1].posterPath, "/videos/4/preview?kind=show")
    }

    func testSeasonsSplit() {
        let groups = ShowGroup.group([
            episode(1, show: "The Bear", season: 2, ep: 1),
            episode(2, show: "The Bear", season: 1, ep: 1),
        ])
        let seasons = groups[0].seasons()
        XCTAssertEqual(seasons.map(\.number), [1, 2])
        XCTAssertEqual(seasons[1].episodes.map(\.id), [1])
    }

    func testIgnoresVideosWithoutShowTitle() {
        let movie = Video(id: 9, url: "/m", title: "Akira", platform: nil, sourceKey: nil,
                          previewUrl: nil, classification: "movies", position: 9,
                          status: "done", errorMsg: nil, streamPath: "/videos/9/stream",
                          source: "library")
        XCTAssertTrue(ShowGroup.group([movie]).isEmpty)
    }
}
