import XCTest
@testable import PatataTubeKit

final class GridDisplayModeTests: XCTestCase {
    func testSentinelIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(70), .list)
    }

    func testAnythingBelowTheFloorIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(169), .list)
    }

    func testTheFloorIsStillAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(170), .grid(cellSize: 170))
    }

    func testCeilingIsAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(420), .grid(cellSize: 420))
    }

    func testSmallerFromTheFloorOffersListView() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 170),
                       GridSizeStep(title: "List view",
                                    systemImage: "list.bullet",
                                    target: 70))
    }

    func testSmallerAboveTheFloorStepsDown() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 295),
                       GridSizeStep(title: "Smaller cells",
                                    systemImage: "minus.magnifyingglass",
                                    target: 170))
    }

    func testSmallerClampsToTheFloor() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 250)?.target, 170)
    }

    func testSmallerIsDisabledInList() {
        XCTAssertNil(GridDisplayMode.smaller(from: 70))
    }

    func testBiggerFromListReturnsToTheGrid() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 70),
                       GridSizeStep(title: "Grid view",
                                    systemImage: "square.grid.2x2",
                                    target: 170))
    }

    func testBiggerStepsUp() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 170),
                       GridSizeStep(title: "Bigger cells",
                                    systemImage: "plus.magnifyingglass",
                                    target: 295))
    }

    func testBiggerClampsToTheCeiling() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 400)?.target, 420)
    }

    func testBiggerIsDisabledAtTheCeiling() {
        XCTAssertNil(GridDisplayMode.bigger(from: 420))
    }

    func testCanonicalSizesAreListAndTheThreeGridStops() {
        XCTAssertEqual(GridDisplayMode.canonicalSizes, [70, 170, 295, 420])
    }

    func testClampedCellSizeClampsBelowList() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(10), 70)
    }

    func testClampedCellSizeClampsAboveCeiling() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(999), 420)
    }

    func testClampedCellSizePassesThroughMidRange() {
        XCTAssertEqual(GridDisplayMode.clampedCellSize(250), 250)
    }

    func testNearestCanonicalSizeSnapsToExactStops() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 70), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 170), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 295), 295)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 420), 420)
    }

    func testNearestCanonicalSizeRoundsToCloserNeighbor() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 100), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 150), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 250), 295)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 400), 420)
    }

    func testNearestCanonicalSizeTiesRoundDown() {
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 120), 70)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 232.5), 170)
        XCTAssertEqual(GridDisplayMode.nearestCanonicalSize(to: 357.5), 295)
    }
}
