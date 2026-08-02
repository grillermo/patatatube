import XCTest
@testable import PatataTubeKit

final class ResumeDecisionTests: XCTestCase {
    func testAsksWhenPastThresholdOnMovies() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 120, classification: "movies"),
                       .ask(secs: 120))
    }

    func testAsksOnTv() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 61, classification: "tv"),
                       .ask(secs: 61))
    }

    func testDoesNotAskBelowThreshold() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 59.9, classification: "movies"),
                       .playFromStart)
    }

    func testAsksAtExactThreshold() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 60.0, classification: "movies"),
                       .ask(secs: 60.0))
    }

    func testDoesNotAskAtZero() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 0, classification: "tv"),
                       .playFromStart)
    }

    func testDoesNotAskForOtherClassifications() {
        for classification in ["children", "adults", "education"] {
            XCTAssertEqual(ResumeDecision.decide(resumeSecs: 500, classification: classification),
                           .playFromStart, classification)
        }
    }

    func testDoesNotAskWithoutClassification() {
        XCTAssertEqual(ResumeDecision.decide(resumeSecs: 500, classification: nil),
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
