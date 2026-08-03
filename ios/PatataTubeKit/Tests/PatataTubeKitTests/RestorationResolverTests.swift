import XCTest
@testable import PatataTubeKit

final class RestorationResolverTests: XCTestCase {
    func testGroupRouteRoundTripsByID() throws {
        let state = RestorationState(
            feed: .group(id: 4), path: [.group(id: 4)], search: "",
            scrollAnchors: [:], player: nil, tab: .videos
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(RestorationState.self, from: data), state)
    }

    private func episode(_ id: Int, show: String, season: Int, ep: Int) -> Video {
        Video(id: id, url: "/x", title: "E\(ep)", platform: nil, sourceKey: nil,
              previewUrl: nil, groupID: nil, plexKind: .tv, position: id, status: "done",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: show, season: season, episode: ep,
              summary: nil, showPreviewUrl: nil)
    }

    private func movie(_ id: Int) -> Video {
        Video(id: id, url: "/x", title: "M\(id)", platform: nil, sourceKey: nil,
              previewUrl: nil, groupID: nil, plexKind: .movies, position: id, status: "done",
              errorMsg: nil, streamPath: "/videos/\(id)/stream", source: "library",
              showTitle: nil, season: nil, episode: nil,
              summary: nil, showPreviewUrl: nil)
    }

    private func state(path: [Route], player: PlayerState? = nil,
                       search: String = "") -> RestorationState {
        RestorationState(feed: .plex(.tv), path: path, search: search,
                         scrollAnchors: [:], player: player)
    }

    func testResolvesShowAndMovieRoutes() {
        let videos = [episode(1, show: "The Bear", season: 1, ep: 1), movie(9)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear")]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.show(title: "The Bear")])

        let movieResolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 9)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(movieResolved.path, [.movie(id: 9)])
    }

    func testDownloadsRouteAlwaysResolves() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [.downloads]), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.downloads])
    }

    func testDroppedShowTruncatesEverythingAfterIt() {
        let videos = [movie(9)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear"), .movie(id: 9)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [])
    }

    func testDroppedMovieIsRemoved() {
        let videos = [episode(1, show: "The Bear", season: 1, ep: 1)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear"), .movie(id: 404)]),
            videos: videos, hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.show(title: "The Bear")])
    }

    func testPlayerQueueComesFromTheRestoredShow() {
        let videos = [
            episode(1, show: "The Bear", season: 1, ep: 1),
            episode(2, show: "The Bear", season: 1, ep: 2),
            movie(9),
        ]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.show(title: "The Bear")],
                         player: PlayerState(videoID: 2, versionID: nil, sleepMode: false)),
            videos: videos, hasPendingQuickAction: false)

        XCTAssertEqual(resolved.player?.video.id, 2)
        XCTAssertEqual(resolved.player?.queue.map(\.id), [1, 2])
        XCTAssertEqual(resolved.player?.sleepMode, false)
    }

    func testPlayerQueueIsTheWholeListWithoutAShowRoute() {
        let videos = [movie(9), movie(10)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 10)],
                         player: PlayerState(videoID: 10, versionID: nil, sleepMode: true)),
            videos: videos, hasPendingQuickAction: false)

        XCTAssertEqual(resolved.player?.queue.map(\.id), [9, 10])
        XCTAssertEqual(resolved.player?.sleepMode, true)
    }

    func testPlayerDroppedWhenItsVideoIsGone() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], player: PlayerState(videoID: 404, versionID: nil, sleepMode: false)),
            videos: [movie(9)], hasPendingQuickAction: false)
        XCTAssertNil(resolved.player)
    }

    func testPendingQuickActionSuppressesPlayerButKeepsPath() {
        let videos = [movie(9)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.movie(id: 9)],
                         player: PlayerState(videoID: 9, versionID: nil, sleepMode: false)),
            videos: videos, hasPendingQuickAction: true)
        XCTAssertNil(resolved.player)
        XCTAssertEqual(resolved.path, [.movie(id: 9)])
    }

    func testSearchIsPassedThrough() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], search: "bear"), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.search, "bear")
    }

    func testEmptyStateResolvesToNothing() {
        let resolved = RestorationResolver.resolve(
            state: .empty, videos: [movie(9)], hasPendingQuickAction: false)
        XCTAssertEqual(resolved, ResolvedRestoration(path: [], search: "", player: nil))
    }
}
