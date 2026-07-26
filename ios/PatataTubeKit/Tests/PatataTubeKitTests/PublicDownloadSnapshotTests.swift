import Foundation
import Testing
import PatataTubeKit

@Suite("Download snapshot public APIs")
struct PublicDownloadSnapshotTests {
    @Test func publicInitializersExposeSnapshotValues() {
        let activity = DownloadActivity(
            videoID: 7,
            versionID: 2,
            progress: 0.5,
            transferredByteCount: 5_000,
            totalByteCount: 10_000
        )
        let completedAt = Date(timeIntervalSinceReferenceDate: 42)
        let completion = DownloadCompletion(
            videoID: 7,
            versionID: 2,
            completedAt: completedAt
        )

        #expect(activity.videoID == 7)
        #expect(activity.transferredByteCount == 5_000)
        #expect(completion.completedAt == completedAt)
    }
}
