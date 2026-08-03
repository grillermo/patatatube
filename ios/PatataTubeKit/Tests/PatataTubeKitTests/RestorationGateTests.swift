import XCTest
@testable import PatataTubeKit

final class RestorationGateTests: XCTestCase {
    func testFirstClaimSucceedsAndLaterOnesDoNot() {
        let gate = RestorationGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    func testSeparateGatesAreIndependent() {
        XCTAssertTrue(RestorationGate().claim())
        XCTAssertTrue(RestorationGate().claim())
    }

    func testResetAllowsOneMoreClaim() {
        let gate = RestorationGate()
        XCTAssertTrue(gate.claim())
        gate.reset()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    /// The `.task` that claims this can be restarted from more than one
    /// SwiftUI update at once; exactly one of them must win.
    func testConcurrentClaimsYieldExactlyOneWinner() {
        let gate = RestorationGate()
        let winners = NSMutableArray()
        let lock = NSLock()
        let group = DispatchGroup()

        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                let won = gate.claim()
                if won {
                    lock.lock()
                    winners.add(true)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(winners.count, 1)
    }
}
