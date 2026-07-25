// CapturedRangesTests.swift
import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured range algebra")
struct CapturedRangesTests {
    private func r(_ s: Int64, _ e: Int64) -> DownloadByteRange { .init(start: s, end: e) }

    @Test func insertingMergesOverlapAndAdjacency() {
        var ranges: [DownloadByteRange] = []
        ranges = CapturedRanges.inserting(r(0, 4), into: ranges)
        ranges = CapturedRanges.inserting(r(5, 9), into: ranges)   // adjacent → merge
        #expect(ranges == [r(0, 9)])
        ranges = CapturedRanges.inserting(r(20, 25), into: ranges)
        #expect(ranges == [r(0, 9), r(20, 25)])
        ranges = CapturedRanges.inserting(r(8, 22), into: ranges)  // overlaps both → one span
        #expect(ranges == [r(0, 25)])
    }

    @Test func insertingKeepsSortedAndDedupes() {
        var ranges: [DownloadByteRange] = []
        ranges = CapturedRanges.inserting(r(30, 39), into: ranges)
        ranges = CapturedRanges.inserting(r(0, 9), into: ranges)
        ranges = CapturedRanges.inserting(r(0, 9), into: ranges)   // duplicate
        #expect(ranges == [r(0, 9), r(30, 39)])
    }

    @Test func complementReturnsGaps() {
        let ranges = [r(0, 9), r(20, 29)]
        #expect(CapturedRanges.complement(of: ranges, over: 40) == [r(10, 19), r(30, 39)])
        #expect(CapturedRanges.complement(of: [r(0, 39)], over: 40) == [])
        #expect(CapturedRanges.complement(of: [], over: 40) == [r(0, 39)])
    }

    @Test func coveredBytesAndCompleteness() {
        let ranges = [r(0, 9), r(20, 29)]
        #expect(CapturedRanges.coveredBytes(ranges) == 20)
        #expect(CapturedRanges.isComplete(ranges, total: 40) == false)
        #expect(CapturedRanges.isComplete([r(0, 39)], total: 40) == true)
    }
}
