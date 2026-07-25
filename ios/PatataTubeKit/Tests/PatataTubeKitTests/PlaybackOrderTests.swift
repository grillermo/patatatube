import XCTest
@testable import PatataTubeKit

/// Deterministic RNG so shuffle tests aren't flaky: a tiny fixed-seed LCG.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class PlaybackOrderTests: XCTestCase {
    func testZeroCountReturnsEmpty() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 0, using: &rng), [])
    }

    func testSingleCountReturnsSingleElement() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 1, using: &rng), [0])
    }

    func testResultIsAlwaysAPermutationOfTheFullRange() {
        var rng = SeededRNG(seed: 42)
        let order = shuffledPlaybackOrder(count: 10, using: &rng)
        XCTAssertEqual(order.sorted(), Array(0..<10))
    }

    func testPinFirstForcesThatIndexToTheFront() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            var rng = SeededRNG(seed: seed)
            let order = shuffledPlaybackOrder(count: 8, pinFirst: 5, using: &rng)
            XCTAssertEqual(order.first, 5)
            XCTAssertEqual(order.sorted(), Array(0..<8))
        }
    }

    func testAvoidFirstNeverLandsAtTheFrontWhenMoreThanOneElement() {
        for seed: UInt64 in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
            var rng = SeededRNG(seed: seed)
            let order = shuffledPlaybackOrder(count: 6, avoidFirst: 3, using: &rng)
            XCTAssertNotEqual(order.first, 3)
            XCTAssertEqual(order.sorted(), Array(0..<6))
        }
    }

    func testAvoidFirstIsIgnoredWhenOnlyOneElement() {
        var rng = SeededRNG(seed: 1)
        XCTAssertEqual(shuffledPlaybackOrder(count: 1, avoidFirst: 0, using: &rng), [0])
    }

    func testPinFirstTakesPrecedenceOverAvoidFirst() {
        var rng = SeededRNG(seed: 1)
        let order = shuffledPlaybackOrder(count: 5, pinFirst: 2, avoidFirst: 2, using: &rng)
        XCTAssertEqual(order.first, 2)
    }

    func testConvenienceOverloadProducesAValidPermutation() {
        let order = shuffledPlaybackOrder(count: 7)
        XCTAssertEqual(order.sorted(), Array(0..<7))
    }
}
