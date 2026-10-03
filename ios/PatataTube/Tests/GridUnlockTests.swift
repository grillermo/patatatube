// ios/PatataTube/Tests/GridUnlockTests.swift
import Testing
import CoreGraphics
@testable import PatataTube

struct GridUnlockTests {
    private typealias C = GridUnlock.Cell

    @Test func checkersPatternUnlocks() {
        var u = GridUnlock()
        #expect(!u.tap(C(column: 0, row: 0)))   // top-left
        #expect(!u.tap(C(column: 0, row: 2)))   // bottom-left
        #expect(!u.tap(C(column: 2, row: 2)))   // bottom-right
        #expect(!u.tap(C(column: 2, row: 0)))   // top-right
        #expect(u.tap(C(column: 1, row: 1)))    // centre
    }

    @Test func sequenceIsExactlyTheCheckersSquares() {
        let even = GridUnlock.sequence.allSatisfy { ($0.column + $0.row) % 2 == 0 }
        #expect(even)
        #expect(Set(GridUnlock.sequence).count == 5)
    }

    @Test func edgeSquareIsWrongAndResets() {
        var u = GridUnlock()
        _ = u.tap(C(column: 0, row: 0))
        #expect(!u.tap(C(column: 0, row: 1)))
        #expect(u.lit.isEmpty)
        #expect(!u.tap(C(column: 0, row: 2)))
        #expect(u.lit.isEmpty)
    }

    @Test func cellFromPoint() {
        let size = CGSize(width: 300, height: 300)
        #expect(GridUnlock.cell(at: CGPoint(x: 10, y: 10), in: size) == C(column: 0, row: 0))
        #expect(GridUnlock.cell(at: CGPoint(x: 150, y: 150), in: size) == C(column: 1, row: 1))
        #expect(GridUnlock.cell(at: CGPoint(x: 290, y: 290), in: size) == C(column: 2, row: 2))
        #expect(GridUnlock.cell(at: CGPoint(x: 300, y: 300), in: size) == C(column: 2, row: 2))
    }
}
