import Clocks
import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

@Suite("Download button state", .serialized)
@MainActor
struct DownloadButtonStateTests {
    @Test func observedCacheStateDrivesIdleRenderingAndClampsProgress() {
        let state = DownloadButtonState()
        #expect(state.effectiveState == .notCached)

        state.observe(.downloading(-0.25))
        #expect(state.effectiveState == .downloading(-0.25))
        #expect(state.clampedProgress == 0)

        state.observe(.downloading(1.25))
        #expect(state.effectiveState == .downloading(1.25))
        #expect(state.clampedProgress == 1)

        state.observe(.cached)
        #expect(state.effectiveState == .cached)
        #expect(state.clampedProgress == 1)
    }

    @Test func currentAttemptAppliesSuccessAndFailure() {
        let state = DownloadButtonState()
        let successID = UUID()

        state.begin(attemptID: successID)
        #expect(state.effectiveState == .downloading(0))
        state.finish(attemptID: successID, succeeded: true)
        #expect(state.effectiveState == .cached)

        state.reset(to: .notCached)
        let failureID = UUID()
        state.begin(attemptID: failureID)
        state.finish(attemptID: failureID, succeeded: false)
        #expect(state.effectiveState == .notCached)
    }

    @Test func staleCompletionCannotOverwriteCancelRetryOrReset() {
        let state = DownloadButtonState()
        let cancelledID = UUID()
        let retryID = UUID()

        state.begin(attemptID: cancelledID)
        state.cancel()
        state.begin(attemptID: retryID)
        state.finish(attemptID: cancelledID, succeeded: false)
        #expect(state.activeAttemptID == retryID)
        #expect(state.effectiveState == .downloading(0))

        state.reset(to: .downloading(0.4))
        state.finish(attemptID: retryID, succeeded: true)
        #expect(state.effectiveState == .downloading(0.4))
    }
}
