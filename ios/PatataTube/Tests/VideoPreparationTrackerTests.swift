import Testing
@testable import PatataTube

@Suite("Video preparation tracker", .serialized)
@MainActor
struct VideoPreparationTrackerTests {
    private enum ExpectedError: Error {
        case failed
    }

    @Test func tracksIndependentVideosAndBalancedOperations() {
        let tracker = VideoPreparationTracker()

        tracker.begin(videoID: 1)
        tracker.begin(videoID: 1)
        tracker.begin(videoID: 2)

        #expect(tracker.isPreparing(videoID: 1))
        #expect(tracker.isPreparing(videoID: 2))

        tracker.end(videoID: 1)
        #expect(tracker.isPreparing(videoID: 1))

        tracker.end(videoID: 1)
        tracker.end(videoID: 2)
        #expect(!tracker.isPreparing(videoID: 1))
        #expect(!tracker.isPreparing(videoID: 2))
    }

    @Test func trackClearsPreparationAfterFailure() async {
        let tracker = VideoPreparationTracker()

        do {
            try await tracker.track(videoID: 7) {
                #expect(tracker.isPreparing(videoID: 7))
                throw ExpectedError.failed
            }
            Issue.record("Expected preparation to throw")
        } catch ExpectedError.failed {
            #expect(!tracker.isPreparing(videoID: 7))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func trackIfIdleSuppressesASecondOperation() async {
        let tracker = VideoPreparationTracker()
        tracker.begin(videoID: 9)
        var operationCount = 0

        let result = await tracker.trackIfIdle(videoID: 9) {
            operationCount += 1
            return 42
        }

        #expect(result == nil)
        #expect(operationCount == 0)
        tracker.end(videoID: 9)
    }
}
