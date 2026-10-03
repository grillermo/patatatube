// ios/PatataTube/Tests/QuadrantUnlockTests.swift
import Testing
import CoreGraphics
@testable import PatataTube

struct QuadrantUnlockTests {
    @Test func counterClockwiseOrderUnlocks() {
        var u = QuadrantUnlock()
        #expect(!u.tap(.topLeft))
        #expect(!u.tap(.bottomLeft))
        #expect(!u.tap(.bottomRight))
        #expect(u.tap(.topRight))
    }

    @Test func wrongTapResetsAndRequiresTopLeftAgain() {
        var u = QuadrantUnlock()
        _ = u.tap(.topLeft)
        #expect(!u.tap(.topRight))
        #expect(u.lit.isEmpty)
        #expect(!u.tap(.bottomLeft))
        #expect(u.lit.isEmpty)
    }

    @Test func quadrantFromPoint() {
        let size = CGSize(width: 100, height: 100)
        #expect(QuadrantUnlock.quadrant(at: CGPoint(x: 10, y: 10), in: size) == .topLeft)
        #expect(QuadrantUnlock.quadrant(at: CGPoint(x: 10, y: 90), in: size) == .bottomLeft)
        #expect(QuadrantUnlock.quadrant(at: CGPoint(x: 90, y: 90), in: size) == .bottomRight)
        #expect(QuadrantUnlock.quadrant(at: CGPoint(x: 90, y: 10), in: size) == .topRight)
    }
}
