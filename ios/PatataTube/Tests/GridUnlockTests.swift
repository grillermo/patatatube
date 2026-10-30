// ios/PatataTube/Tests/GridUnlockTests.swift
import Testing
import CoreGraphics
@testable import PatataTube

struct GridUnlockTests {
    private typealias C = GridUnlock.Cell

    @Test func checkersPatternUnlocks() {
        // #expect can't call a mutating method, so each tap is taken first.
        var u = GridUnlock()
        let topLeft = u.tap(C(column: 0, row: 0))
        let bottomLeft = u.tap(C(column: 0, row: 2))
        let bottomRight = u.tap(C(column: 2, row: 2))
        let topRight = u.tap(C(column: 2, row: 0))
        let centre = u.tap(C(column: 1, row: 1))
        #expect(!topLeft)
        #expect(!bottomLeft)
        #expect(!bottomRight)
        #expect(!topRight)
        #expect(centre)
    }

    @Test func sequenceIsExactlyTheCheckersSquares() {
        let even = GridUnlock.sequence.allSatisfy { ($0.column + $0.row) % 2 == 0 }
        #expect(even)
        #expect(Set(GridUnlock.sequence).count == 5)
    }

    @Test func edgeSquareIsWrongAndResets() {
        var u = GridUnlock()
        _ = u.tap(C(column: 0, row: 0))
        let edge = u.tap(C(column: 0, row: 1))
        #expect(!edge)
        #expect(u.lit.isEmpty)
        let outOfOrder = u.tap(C(column: 0, row: 2))
        #expect(!outOfOrder)
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
