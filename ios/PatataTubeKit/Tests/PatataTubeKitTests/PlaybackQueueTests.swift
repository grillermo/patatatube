import XCTest
@testable import PatataTubeKit

final class PlaybackQueueTests: XCTestCase {
    private func video(id: Int, title: String? = nil) -> Video {
        Video(id: id, url: "https://example.com/\(id)", title: title, platform: nil,
              sourceKey: nil, previewUrl: nil, classification: "children",
              position: nil, status: "done", errorMsg: nil, streamPath: "/videos/\(id)/stream")
    }

    func testVideoInSnapshotReplacesItsRowAndPointsAtIt() {
        let snapshot = [video(id: 1), video(id: 2), video(id: 3)]
        let updated = video(id: 2, title: "fresh copy")

        let queue = PlaybackQueue(video: updated, queueSnapshot: snapshot)

        XCTAssertEqual(queue.startIndex, 1)
        XCTAssertEqual(queue.videos.map(\.id), [1, 2, 3])
        XCTAssertEqual(queue.videos[1].title, "fresh copy")
        XCTAssertEqual(queue.id, 2)
    }

    func testVideoMissingFromSnapshotFallsBackToSingleItemQueue() {
        let snapshot = [video(id: 1), video(id: 3)]
        let tapped = video(id: 2)

        let queue = PlaybackQueue(video: tapped, queueSnapshot: snapshot)

        XCTAssertEqual(queue.videos.map(\.id), [2])
        XCTAssertEqual(queue.startIndex, 0)
    }

    func testEmptySnapshotNeverProducesEmptyQueue() {
        let tapped = video(id: 7)

        let queue = PlaybackQueue(video: tapped, queueSnapshot: [])

        XCTAssertEqual(queue.videos.map(\.id), [7])
        XCTAssertEqual(queue.startIndex, 0)
        XCTAssertTrue(queue.videos.indices.contains(queue.startIndex))
    }

    func testSleepModeDefaultsFalseAndIsCarried() {
        let tapped = video(id: 4)
        XCTAssertFalse(PlaybackQueue(video: tapped, queueSnapshot: []).sleepMode)
        XCTAssertTrue(PlaybackQueue(video: tapped, queueSnapshot: [], sleepMode: true).sleepMode)
    }

    func testStartSecsDefaultsToZero() {
        let tapped = video(id: 1)
        let queue = PlaybackQueue(video: tapped, queueSnapshot: [tapped])

        XCTAssertEqual(queue.startSecs, 0)
    }

    func testStartSecsIsCarried() {
        let tapped = video(id: 1)
        let queue = PlaybackQueue(video: tapped, queueSnapshot: [tapped], startSecs: 91.5)

        XCTAssertEqual(queue.startSecs, 91.5)
    }

    func testStartPausedDefaultsToFalseAndRoundTrips() {
        let video = Video(id: 1, url: "/x", title: "A", platform: nil, sourceKey: nil,
                          previewUrl: nil, classification: "movies", position: 1,
                          status: "done", errorMsg: nil, streamPath: "/videos/1/stream",
                          source: "library", showTitle: nil, season: nil, episode: nil,
                          summary: nil, showPreviewUrl: nil)

        XCTAssertFalse(PlaybackQueue(video: video, queueSnapshot: [video]).startPaused)
        XCTAssertTrue(
            PlaybackQueue(video: video, queueSnapshot: [video],
                          startSecs: 30, startPaused: true).startPaused
        )
    }
}
