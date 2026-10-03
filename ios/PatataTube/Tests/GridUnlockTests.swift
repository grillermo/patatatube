// ios/PatataTube/Tests/GridUnlockTests.swift
import Testing
import CoreGraphics
@testable import PatataTube

struct GridUnlockTests {
    private typealias C = GridUnlock.Cell

    @Test func everyOtherSquareCounterClockwiseUnlocks() {
        var u = GridUnlock()
        #expect(!u.tap(C(column: 0, row: 0)))   // top-left
        #expect(!u.tap(C(column: 0, row: 2)))   // bottom-left
        #expect(u.tap(C(column: 1, row: 1)))    // middle-right
    }

    @Test func skippedSquareIsWrongAndResets() {
        var u = GridUnlock()
        _ = u.tap(C(column: 0, row: 0))
        #expect(!u.tap(C(column: 0, row: 1)))   // middle-left: the one in between
        #expect(u.lit.isEmpty)
        #expect(!u.tap(C(column: 0, row: 2)))   // must start from top-left again
        #expect(u.lit.isEmpty)
    }

    @Test func cellFromPoint() {
        let size = CGSize(width: 100, height: 300)
        #expect(GridUnlock.cell(at: CGPoint(x: 10, y: 10), in: size) == C(column: 0, row: 0))
        #expect(GridUnlock.cell(at: CGPoint(x: 10, y: 290), in: size) == C(column: 0, row: 2))
        #expect(GridUnlock.cell(at: CGPoint(x: 90, y: 150), in: size) == C(column: 1, row: 1))
        #expect(GridUnlock.cell(at: CGPoint(x: 100, y: 300), in: size) == C(column: 1, row: 2))
    }
}
