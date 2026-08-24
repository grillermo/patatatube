import XCTest
@testable import PatataTubeKit

final class QueueNavigatorTests: XCTestCase {
    private func video(id: Int) -> Video {
        Video(id: id, url: "https://example.com/\(id)", title: "Video \(id)", platform: nil,
              sourceKey: nil, previewUrl: nil, groupID: 1, plexKind: nil,
              position: nil, status: "done", errorMsg: nil, streamPath: "/videos/\(id)/stream")
    }

    /// Playable-only pool: ids listed in `unplayable` report false.
    private func navigator(ids: [Int], startIndex: Int, randomize: Bool,
                           unplayable: Set<Int> = []) -> QueueNavigator {
        QueueNavigator(videos: ids.map(video(id:)), startIndex: startIndex,
                       randomize: randomize, isPlayable: { !unplayable.contains($0.id) })
    }

    func testSequentialStepsForwardOneAtATime() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: false)
        XCTAssertEqual(nav.step(direction: 1), 1)
        XCTAssertEqual(nav.currentIndex, 1)
        XCTAssertEqual(nav.step(direction: 1), 2)
        XCTAssertEqual(nav.currentVideo?.id, 3)
    }

    func testSequentialStopsAtTheEndOfTheQueue() {
        var nav = navigator(ids: [1, 2], startIndex: 1, randomize: false)
        XCTAssertNil(nav.step(direction: 1))
        XCTAssertEqual(nav.currentIndex, 1, "a refused step must not move the cursor")
    }

    func testSequentialSkipsUnplayableEntries() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: false, unplayable: [2])
        XCTAssertEqual(nav.step(direction: 1), 2)
        XCTAssertEqual(nav.currentVideo?.id, 3)
    }

    func testSequentialStepsBackwardAndReportsQueueStart() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 2, randomize: false)
        XCTAssertFalse(nav.isAtQueueStart)
        XCTAssertEqual(nav.step(direction: -1), 1)
        XCTAssertEqual(nav.step(direction: -1), 0)
        XCTAssertTrue(nav.isAtQueueStart)
        XCTAssertNil(nav.step(direction: -1))
    }

    func testRandomizeTurnedOnMidQueueTakesEffectOnTheNextStep() {
        // The audio mini-player's shuffle toggle flips this while the queue is
        // already running; a snapshot taken at start() left "next" sequential.
        var nav = navigator(ids: [1, 2, 3, 4], startIndex: 0, randomize: false)
        XCTAssertEqual(nav.step(direction: 1), 1)
        nav.setRandomize(true)
        XCTAssertTrue(nav.randomize)
        XCTAssertEqual(nav.currentVideo?.id, 2, "enabling must not move the current item")
        var seen = [2]
        for _ in 0..<3 {
            guard let next = nav.step(direction: 1) else { return XCTFail("random step ran dry") }
            seen.append(nav.videos[next].id)
        }
        XCTAssertEqual(Set(seen), [1, 2, 3, 4], "the shuffle covers the pool from the current item")
    }

    func testRandomizeTurnedOffMidQueueResumesSequentiallyFromTheCurrentItem() {
        var nav = navigator(ids: [1, 2, 3, 4], startIndex: 2, randomize: true)
        _ = nav.step(direction: 1)
        let index = nav.currentIndex
        nav.setRandomize(false)
        XCTAssertFalse(nav.randomize)
        XCTAssertEqual(nav.currentIndex, index, "disabling must not move the current item")
        let expected: Int? = index + 1 < 4 ? index + 1 : nil
        XCTAssertEqual(nav.step(direction: 1), expected, "sequential stepping resumes from there")
    }

    func testRandomizeSetToItsCurrentValueKeepsTheExistingOrder() {
        var nav = navigator(ids: [1, 2, 3, 4], startIndex: 0, randomize: true)
        _ = nav.step(direction: 1)
        _ = nav.step(direction: 1)
        XCTAssertFalse(nav.isAtQueueStart)
        nav.setRandomize(true)
        XCTAssertFalse(nav.isAtQueueStart, "a no-op set must not reseed the order")
    }

    func testRandomStartsAtTheTappedVideoAndVisitsEveryPlayableOneBeforeRepeating() {
        var nav = navigator(ids: [1, 2, 3, 4], startIndex: 2, randomize: true)
        XCTAssertEqual(nav.currentVideo?.id, 3, "the tapped video plays first")
        var seen = [3]
        for _ in 0..<3 {
            guard let next = nav.step(direction: 1) else { return XCTFail("random step ran dry") }
            seen.append(nav.videos[next].id)
        }
        XCTAssertEqual(Set(seen), [1, 2, 3, 4])
    }

    func testRandomReshuffleNeverRepeatsAVideoBackToBack() {
        // 2 playable entries: the reshuffle at the wrap point must not put the
        // just-finished video first, or autoplay's loop replays it immediately.
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: true)
        var ids = [nav.currentVideo?.id]
        for _ in 0..<6 {
            guard let next = nav.step(direction: 1) else { return XCTFail("random step ran dry") }
            ids.append(nav.videos[next].id)
        }
        for (previous, current) in zip(ids, ids.dropFirst()) {
            XCTAssertNotEqual(previous, current, "back-to-back repeat in \(ids)")
        }
    }

    func testRandomExcludesUnplayableEntriesFromThePool() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: true, unplayable: [2, 3])
        // With only video 1 playable, the pool has one entry, so forward reshuffle produces [0]
        // again, which is the legitimate behavior for a single-entry pool
        XCTAssertEqual(nav.step(direction: 1), 0)
        XCTAssertTrue(nav.hasAnyPlayable, "video 1 is still playable")
    }

    func testRandomBackwardWalksTheCursorAndStopsAtPositionZero() {
        var nav = navigator(ids: [1, 2, 3], startIndex: 0, randomize: true)
        XCTAssertTrue(nav.isAtQueueStart)
        XCTAssertNil(nav.step(direction: -1))
        XCTAssertNotNil(nav.step(direction: 1))
        XCTAssertFalse(nav.isAtQueueStart)
        XCTAssertNotNil(nav.step(direction: -1))
        XCTAssertTrue(nav.isAtQueueStart)
    }

    func testNothingPlayableAnywhereRefusesEveryStep() {
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: false, unplayable: [1, 2])
        XCTAssertFalse(nav.hasAnyPlayable)
        XCTAssertNil(nav.step(direction: 1))
        XCTAssertFalse(nav.peekHasNext())
    }

    func testPeekDoesNotMoveTheCursor() {
        var nav = navigator(ids: [1, 2], startIndex: 0, randomize: false)
        XCTAssertTrue(nav.peekHasNext())
        XCTAssertEqual(nav.currentIndex, 0)
    }
}
