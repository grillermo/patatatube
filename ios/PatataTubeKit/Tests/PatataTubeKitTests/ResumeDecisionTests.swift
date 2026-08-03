import XCTest
@testable import PatataTubeKit

final class ResumeDecisionTests: XCTestCase {
    func testPromptsForAPlexItemPastSixtySeconds() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, plexKind: .movies),
                       .ask(secs: 120))
    }

    func testAsksOnTv() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 61, plexKind: .tv),
                       .ask(secs: 61))
    }

    func testDoesNotAskBelowThreshold() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 59.9, plexKind: .movies),
                       .playFromStart)
    }

    func testAsksAtExactThreshold() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 60.0, plexKind: .movies),
                       .ask(secs: 60.0))
    }

    func testDoesNotAskAtZero() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 0, plexKind: .tv),
                       .playFromStart)
    }

    func testDoesNotPromptForAGroupVideo() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, plexKind: nil),
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
}
