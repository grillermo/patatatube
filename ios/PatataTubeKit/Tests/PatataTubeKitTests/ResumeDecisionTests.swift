import XCTest
@testable import PatataTubeKit

final class ResumeDecisionTests: XCTestCase {
    func testDoesNotPromptForAGroupVideo() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120),
                       .playFromStart)
    }

    func testTimestampUnderAnHour() {
        XCTAssertEqual(ResumeDecision.timestamp(1453), "24:13")
    }

    func testTimestampOverAnHour() {
        XCTAssertEqual(ResumeDecision.timestamp(5053), "1:24:13")
    }

    func testTimestampFloorsFractions() {
        XCTAssertEqual(ResumeDecision.timestamp(59.9), "0:59")
    }

    func testAsksForAGroupVideoThatRemembersPosition() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 120, remembersPosition: true),
            .ask(secs: 120)
        )
    }

    func testDoesNotAskForAGroupVideoThatDoesNotRemember() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 120, remembersPosition: false),
            .playFromStart
        )
    }

    func testARememberingGroupVideoStillRespectsTheFloor() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 59.9, remembersPosition: true),
            .playFromStart
        )
    }

    func testARememberingGroupVideoAsksAtExactlyTheFloor() {
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 60.0, remembersPosition: true),
            .ask(secs: 60.0)
        )
    }

    func testAFinishedRememberingGroupVideoDoesNotAsk() {
        // The reporter writes 0 once playback reaches the final seconds, so a
        // watched video reads as playFromStart without any extra upper bound.
        XCTAssertEqual(
            ResumeDecision.decide(resumeSecs: 0, remembersPosition: true),
            .playFromStart
        )
    }

}
