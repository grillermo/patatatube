import XCTest
@testable import PatataTubeKit

@MainActor
final class VisibleItemsTrackerTests: XCTestCase {
    func testTopmostIsEarliestInOrder() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c", "d"])
        tracker.appeared("c")
        tracker.appeared("b")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testDisappearingTheTopItemAdvancesTopmost() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.disappeared("a")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testDisappearAfterLaterAppearStillTracks() {
        // SwiftUI can deliver the outgoing cell's disappear after the incoming
        // cell's appear; order of callbacks must not decide the answer.
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.appeared("c")
        tracker.disappeared("b")
        tracker.disappeared("a")
        XCTAssertEqual(tracker.topmost, "c")
    }

    func testNothingVisibleIsNil() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b"])
        tracker.appeared("a")
        tracker.disappeared("a")
        XCTAssertNil(tracker.topmost)
    }

    func testIdsNotInOrderAreIgnored() {
        // A cell from the previous tab can report a disappear after the list
        // has already been replaced.
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b"])
        tracker.appeared("zz")
        XCTAssertNil(tracker.topmost)
        tracker.appeared("b")
        XCTAssertEqual(tracker.topmost, "b")
    }

    func testSetOrderDropsVisibleIdsThatVanished() {
        let tracker = VisibleItemsTracker()
        tracker.setOrder(["a", "b", "c"])
        tracker.appeared("a")
        tracker.appeared("b")
        tracker.setOrder(["b", "c"])   // "a" deleted from the list
        XCTAssertEqual(tracker.topmost, "b")
    }
}
