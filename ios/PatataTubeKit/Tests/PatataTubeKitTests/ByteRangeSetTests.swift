import XCTest
@testable import PatataTubeKit

final class ByteRangeSetTests: XCTestCase {
    private func r(_ start: Int64, _ end: Int64) -> DownloadByteRange {
        DownloadByteRange(start: start, end: end)
    }

    func testInsertMergesOverlappingAndAdjacentRuns() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        set.insert(r(20, 29))
        set.insert(r(10, 19)) // adjacent to both → single run
        XCTAssertEqual(set.runs, [r(0, 29)])
        XCTAssertEqual(set.totalBytes, 30)
    }

    func testInsertKeepsDisjointRunsSorted() {
        var set = ByteRangeSet()
        set.insert(r(50, 59))
        set.insert(r(0, 9))
        XCTAssertEqual(set.runs, [r(0, 9), r(50, 59)])
    }

    func testContains() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        XCTAssertTrue(set.contains(r(2, 8)))
        XCTAssertFalse(set.contains(r(5, 12)))
    }

    func testMissingRanges() {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        set.insert(r(50, 59))
        XCTAssertEqual(set.missingRanges(in: r(0, 99)), [r(10, 49), r(60, 99)])
        XCTAssertEqual(set.missingRanges(in: r(0, 9)), [])
        XCTAssertEqual(set.missingRanges(in: r(100, 199)), [r(100, 199)])
    }

    func testPrefixLength() {
        var set = ByteRangeSet()
        set.insert(r(10, 39))
        XCTAssertEqual(set.prefixLength(from: 10, limit: 100), 30)
        XCTAssertEqual(set.prefixLength(from: 15, limit: 10), 10) // capped by limit
        XCTAssertEqual(set.prefixLength(from: 0, limit: 100), 0)  // hole at start
    }

    func testCodableRoundTrip() throws {
        var set = ByteRangeSet()
        set.insert(r(0, 9))
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(ByteRangeSet.self, from: data)
        XCTAssertEqual(decoded, set)
    }
}
