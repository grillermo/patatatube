import XCTest
@testable import PatataTubeKit

final class MediaTabTests: XCTestCase {
    func testGroupsAreTheFourVideoBuckets() {
        XCTAssertEqual(MediaTab.videoGroups, ["children", "adults", "anabel", "asmr"])
    }

    func testFilterPerTab() {
        XCTAssertNil(MediaTab.videos.filter)
        XCTAssertEqual(MediaTab.tv.filter, "tv")
        XCTAssertEqual(MediaTab.movies.filter, "movies")
    }

    func testLabelUppercasesASMRAndCapitalizesTheRest() {
        XCTAssertEqual(MediaTab.label(forGroup: "asmr"), "ASMR")
        XCTAssertEqual(MediaTab.label(forGroup: "children"), "Children")
        XCTAssertEqual(MediaTab.label(forGroup: "anabel"), "Anabel")
    }
}
