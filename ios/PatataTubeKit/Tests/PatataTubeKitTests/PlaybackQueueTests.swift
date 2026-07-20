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
}
