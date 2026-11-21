import XCTest
@testable import PatataTubeKit

final class RestorationResolverTests: XCTestCase {
    func testGroupRouteRoundTripsByID() throws {
        let state = RestorationState(
            feed: .group(id: 4), path: [.group(id: 4)], search: "",
            scrollAnchors: [:], player: nil
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(RestorationState.self, from: data), state)
    }

    private func video(_ id: Int) -> Video {
        Video(id: id, url: "/x", title: "V\(id)", platform: nil, sourceKey: nil,
              previewUrl: nil, groupID: 4, position: id, status: "done",
              errorMsg: nil, streamPath: "/videos/\(id)/stream")
    }

    private func state(path: [Route], player: PlayerState? = nil,
                       search: String = "") -> RestorationState {
        RestorationState(feed: .group(id: 4), path: path, search: search,
                         scrollAnchors: [:], player: player)
    }

    func testGroupAndDownloadsRoutesResolve() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [.group(id: 4), .downloads]), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.path, [.group(id: 4), .downloads])
    }

    func testPlayerQueueIsTheWholeList() {
        let videos = [video(9), video(10)]
        let resolved = RestorationResolver.resolve(
            state: state(path: [.group(id: 4)],
                         player: PlayerState(videoID: 10, versionID: nil, sleepMode: true)),
            videos: videos, hasPendingQuickAction: false)

        XCTAssertEqual(resolved.player?.video.id, 10)
        XCTAssertEqual(resolved.player?.queue.map(\.id), [9, 10])
        XCTAssertEqual(resolved.player?.sleepMode, true)
    }

    func testPlayerDroppedWhenItsVideoIsGone() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], player: PlayerState(videoID: 404, versionID: nil, sleepMode: false)),
            videos: [video(9)], hasPendingQuickAction: false)
        XCTAssertNil(resolved.player)
    }

    func testPendingQuickActionSuppressesPlayerButKeepsPath() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [.group(id: 4)],
                         player: PlayerState(videoID: 9, versionID: nil, sleepMode: false)),
            videos: [video(9)], hasPendingQuickAction: true)
        XCTAssertNil(resolved.player)
        XCTAssertEqual(resolved.path, [.group(id: 4)])
    }

    func testSearchIsPassedThrough() {
        let resolved = RestorationResolver.resolve(
            state: state(path: [], search: "bear"), videos: [],
            hasPendingQuickAction: false)
        XCTAssertEqual(resolved.search, "bear")
    }

    func testEmptyStateResolvesToNothing() {
        let resolved = RestorationResolver.resolve(
            state: .empty, videos: [video(9)], hasPendingQuickAction: false)
        XCTAssertEqual(resolved, ResolvedRestoration(path: [], search: "", player: nil))
    }
}
