import XCTest
@testable import PatataTubeKit

final class RestorationApplyDecisionTests: XCTestCase {
    // MARK: path

    func testAppliesRestoredPathOnlyOntoAnEmptyStack() {
        XCTAssertTrue(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: false, liveIsEmpty: true))
    }

    func testDoesNotRewriteAStackTheUserIsAlreadyOn() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: false, liveIsEmpty: false))
    }

    /// The regression that popped EpisodesView mid-tap: a restore that
    /// resolved to nothing must never clear a live stack.
    func testEmptyRestoredPathNeverClearsALiveStack() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: true, liveIsEmpty: false))
    }

    func testEmptyOntoEmptyIsANoOp() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPath(restoredIsEmpty: true, liveIsEmpty: true))
    }

    // MARK: player

    func testRestoresPlayerWhenNothingIsPlaying() {
        XCTAssertTrue(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: true, hasLivePlayer: false))
    }

    /// The resurrection bug: a restore landing while the player is up (or has
    /// just been dismissed and the snapshot is stale) must not re-present it.
    func testDoesNotReplaceALivePlayer() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: true, hasLivePlayer: true))
    }

    func testNoRestoredPlayerIsANoOp() {
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: false, hasLivePlayer: false))
        XCTAssertFalse(RestorationApplyDecision.shouldApplyPlayer(hasRestoredPlayer: false, hasLivePlayer: true))
    }
}
