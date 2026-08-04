import XCTest
@testable import PatataTubeKit

final class GridDisplayModeTests: XCTestCase {
    func testSentinelIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(70), .list)
    }

    func testAnythingBelowTheFloorIsList() {
        XCTAssertEqual(GridDisplayMode.forCellSize(119), .list)
    }

    func testTheFloorIsStillAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(120), .grid(cellSize: 120))
    }

    func testCeilingIsAGrid() {
        XCTAssertEqual(GridDisplayMode.forCellSize(420), .grid(cellSize: 420))
    }

    func testSmallerFromTheFloorOffersListView() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 120),
                       GridSizeStep(title: "List view",
                                    systemImage: "list.bullet",
                                    target: 70))
    }

    func testSmallerAboveTheFloorStepsDown() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 170),
                       GridSizeStep(title: "Smaller cells",
                                    systemImage: "minus.magnifyingglass",
                                    target: 120))
    }

    func testSmallerClampsToTheFloor() {
        XCTAssertEqual(GridDisplayMode.smaller(from: 150)?.target, 120)
    }

    func testSmallerIsDisabledInList() {
        XCTAssertNil(GridDisplayMode.smaller(from: 70))
    }

    func testBiggerFromListReturnsToTheGrid() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 70),
                       GridSizeStep(title: "Grid view",
                                    systemImage: "square.grid.2x2",
                                    target: 120))
    }

    func testBiggerStepsUp() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 120),
                       GridSizeStep(title: "Bigger cells",
                                    systemImage: "plus.magnifyingglass",
                                    target: 170))
    }

    func testBiggerClampsToTheCeiling() {
        XCTAssertEqual(GridDisplayMode.bigger(from: 400)?.target, 420)
    }

    func testBiggerIsDisabledAtTheCeiling() {
        XCTAssertNil(GridDisplayMode.bigger(from: 420))
    }
}
