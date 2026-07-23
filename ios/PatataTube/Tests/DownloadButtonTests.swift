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

    @Test func armingRequiresCachedAndTogglesDeletePrompt() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        #expect(!state.showsArmedDelete)

        state.arm()
        #expect(state.isArmed)
        #expect(state.showsArmedDelete)

        state.disarm()
        #expect(!state.isArmed)
        #expect(!state.showsArmedDelete)
    }

    @Test func armGenerationAdvancesOnEachArm() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        let first = state.armGeneration
        state.arm()
        state.arm()
        #expect(state.armGeneration == first + 2)
    }

    @Test func leavingCachedClearsArmedState() {
        let state = DownloadButtonState()
        state.reset(to: .cached)
        state.arm()
        #expect(state.isArmed)

        state.observe(.notCached)
        #expect(!state.isArmed)
        #expect(!state.showsArmedDelete)

        state.reset(to: .cached)
        state.arm()
        state.reset(to: .downloading(0.3))
        #expect(!state.isArmed)
    }
}

@MainActor
private final class CacheStateSource {
    var value: CacheState
    private(set) var readCount = 0

    init(_ value: CacheState) {
        self.value = value
    }

    func read() -> CacheState {
        readCount += 1
        return value
    }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var bufferedResult: Bool?

    func wait() async -> Bool {
        if let bufferedResult {
            self.bufferedResult = nil
            return bufferedResult
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ result: Bool) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            bufferedResult = result
        }
    }
}

@MainActor
private func eventually(
    _ message: String,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record(Comment(rawValue: message))
}

@MainActor
private func makeDownloadButton(
    state: DownloadButtonState,
    cache: CacheStateSource = CacheStateSource(.notCached),
    refreshToken: Int = 0,
    tracker: VideoPreparationTracker = VideoPreparationTracker(),
    clock: any Clock<Duration> = ContinuousClock(),
    onDownload: @escaping () async -> Bool = { false },
    onCancel: @escaping () -> Void = {},
    onDeleteCache: @escaping () -> Void = {},
    function: String = #function
) async throws -> DownloadButton {
    return try await withCheckedThrowingContinuation { continuation in
        var button = DownloadButton(
            identity: DownloadButtonIdentity(videoID: 7, versionID: 3, audioLanguage: "eng"),
            refreshToken: refreshToken,
            currentCacheState: { cache.read() },
            onDownload: onDownload,
            onCancel: onCancel,
            onDeleteCache: onDeleteCache,
            state: state
        )
        _ = button.on(\.didAppear, function: function) { view in
            do {
                var resolvedButton = try view.actualView()
                resolvedButton.didAppear = nil
                continuation.resume(returning: resolvedButton)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        ViewHosting.host(
            view: button
                .environment(tracker)
                .environment(\.continuousClock, clock),
            function: function
        )
    }
}

@Suite("Download button view", .serialized)
@MainActor
struct DownloadButtonViewTests {
    @Test func matchingPreparationReplacesControlWithBufferingSpinner() async throws {
        let tracker = VideoPreparationTracker()
        let sut = try await makeDownloadButton(
            state: DownloadButtonState(),
            tracker: tracker
        )

        tracker.begin(videoID: 7)

        let spinner = try sut.inspect().find(ViewType.ProgressView.self)
        #expect(try spinner.accessibilityLabel().string() == "Preparing video")
        #expect(try spinner.fixedWidth() == 44)
        #expect(try spinner.fixedHeight() == 44)
        #expect((try? sut.inspect().find(ViewType.Button.self)) == nil)
    }

    @Test func preparationForAnotherVideoDoesNotReplaceControl() async throws {
        let tracker = VideoPreparationTracker()
        let sut = try await makeDownloadButton(
            state: DownloadButtonState(),
            tracker: tracker
        )

        tracker.begin(videoID: 99)

        let button = try sut.inspect().find(ViewType.Button.self)
        #expect(try button.accessibilityLabel().string() == "Download")
    }

    @Test func completedPreparationRevealsCacheDownloadProgress() async throws {
        let tracker = VideoPreparationTracker()
        let state = DownloadButtonState(initialCacheState: .downloading(0.35))
        let sut = try await makeDownloadButton(state: state, tracker: tracker)

        tracker.begin(videoID: 7)
        #expect((try? sut.inspect().find(ViewType.ProgressView.self)) != nil)

        tracker.end(videoID: 7)
        let button = try sut.inspect().find(ViewType.Button.self)
        #expect(try button.accessibilityLabel().string() == "Cancel download")
        #expect(try button.accessibilityValue().string() == "35%")
    }

    @Test func failedPreparationRestoresIdleDownloadControl() async throws {
        let tracker = VideoPreparationTracker()
        let state = DownloadButtonState()
        let attemptID = state.begin()
        let sut = try await makeDownloadButton(state: state, tracker: tracker)

        tracker.begin(videoID: 7)
        #expect((try? sut.inspect().find(ViewType.ProgressView.self)) != nil)

        tracker.end(videoID: 7)
        state.finish(attemptID: attemptID, succeeded: false)
        let button = try sut.inspect().find(ViewType.Button.self)
        #expect(try button.accessibilityLabel().string() == "Download")
    }

    @Test func rendersAccessibleIdleActiveAndCachedStates() async throws {
        let state = DownloadButtonState()
        let sut = try await makeDownloadButton(state: state)

        var control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Download")

        state.observe(.downloading(1.4))
        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Cancel download")
        #expect(try control.accessibilityValue().string() == "100%")

        state.reset(to: .cached)
        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Downloaded")
    }

    @Test func tappingDownloadShowsLoadingThenAppliesSuccess() async throws {
        let state = DownloadButtonState()
        let gate = DownloadGate()
        let sut = try await makeDownloadButton(
            state: state,
            onDownload: { await gate.wait() }
        )

        try sut.inspect().find(ViewType.Button.self).tap()
        await eventually("Download tap never entered loading") {
            state.effectiveState == .downloading(0)
        }

        await gate.finish(true)
        await eventually("Successful completion never showed cached") {
            state.effectiveState == .cached
        }
    }

    @Test func tappingDownloadReturnsToIdleOnFailure() async throws {
        let state = DownloadButtonState()
        let gate = DownloadGate()
        let sut = try await makeDownloadButton(
            state: state,
            onDownload: { await gate.wait() }
        )

        try sut.inspect().find(ViewType.Button.self).tap()
        await eventually("Download tap never entered loading") { state.isDownloading }
        await gate.finish(false)
        await eventually("Failed completion never returned to idle") {
            state.effectiveState == .notCached
        }
    }

    @Test func tappingRingInvalidatesAttemptBeforeCallingCancel() async throws {
        let state = DownloadButtonState(initialCacheState: .downloading(0.35))
        var cancelCount = 0
        var attemptWasInvalidated = false
        let sut = try await makeDownloadButton(state: state, onCancel: {
            cancelCount += 1
            attemptWasInvalidated = state.activeAttemptID == nil
        })

        state.begin()
        state.observe(.downloading(0.35))
        try sut.inspect().find(ViewType.Button.self).tap()

        #expect(cancelCount == 1)
        #expect(attemptWasInvalidated)
        #expect(state.effectiveState == .notCached)
    }

    @Test func pollingUsesActiveAndInactiveIntervals() async {
        let state = DownloadButtonState()
        let source = CacheStateSource(.downloading(0.25))
        let clock = TestClock()
        let polling = Task {
            await state.poll(currentCacheState: { source.read() }, clock: clock)
        }
        await eventually("Initial cache state was not read") { source.readCount == 1 }

        await clock.advance(by: .milliseconds(149))
        #expect(source.readCount == 1)
        await clock.advance(by: .milliseconds(1))
        await eventually("Active 150 ms poll did not fire") { source.readCount == 2 }

        source.value = .notCached
        await clock.advance(by: .milliseconds(150))
        await eventually("Transition to inactive state was not observed") {
            source.readCount == 3
        }
        await clock.advance(by: .milliseconds(499))
        #expect(source.readCount == 3)
        await clock.advance(by: .milliseconds(1))
        await eventually("Inactive 500 ms poll did not fire") { source.readCount == 4 }

        polling.cancel()
        await clock.run()
    }

    @Test func removingHostedViewStopsPollingWithoutCancellingDownload() async throws {
        let state = DownloadButtonState()
        let source = CacheStateSource(.downloading(0.2))
        let clock = TestClock()
        var cancelCount = 0
        let sut = try await makeDownloadButton(
            state: state,
            cache: source,
            clock: clock,
            onCancel: { cancelCount += 1 }
        )

        ViewHosting.host(view: sut)
        await eventually("Hosted view never started polling") { source.readCount > 0 }
        ViewHosting.expel()
        await Task.yield()
        await clock.run()
        let readsAfterExpel = source.readCount
        await clock.advance(by: .seconds(1))
        await Task.yield()

        #expect(source.readCount == readsAfterExpel)
        #expect(cancelCount == 0)
    }

    @Test func tappingCachedArmsDeletePrompt() async throws {
        let state = DownloadButtonState(initialCacheState: .cached)
        let sut = try await makeDownloadButton(state: state)

        var control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Downloaded")

        try control.tap()
        #expect(state.showsArmedDelete)

        control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Delete download")
    }

    @Test func tappingArmedDeletesCacheAndReturnsToDownload() async throws {
        let state = DownloadButtonState(initialCacheState: .cached)
        var deleteCount = 0
        let sut = try await makeDownloadButton(
            state: state,
            onDeleteCache: { deleteCount += 1 }
        )

        state.arm()
        try sut.inspect().find(ViewType.Button.self).tap()

        #expect(deleteCount == 1)
        #expect(state.effectiveState == .notCached)
        #expect(!state.isArmed)

        let control = try sut.inspect().find(ViewType.Button.self)
        #expect(try control.accessibilityLabel().string() == "Download")
    }

    @Test func armedStateAutoRevertsAfterTimeout() async throws {
        let state = DownloadButtonState(initialCacheState: .cached)
        let clock = TestClock()
        let sut = try await makeDownloadButton(
            state: state,
            cache: CacheStateSource(.cached),
            clock: clock
        )

        ViewHosting.host(view: sut)
        state.arm()
        await eventually("View never observed armed state") { state.isArmed }

        await clock.advance(by: .seconds(3))
        await eventually("Armed state never auto-reverted") { !state.isArmed }

        ViewHosting.expel()
    }
}
