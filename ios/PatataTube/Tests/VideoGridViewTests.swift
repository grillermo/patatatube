import PatataTubeKit
import SwiftUI
import Testing
@testable import PatataTube

@Suite("Video grid error banner", .serialized)
@MainActor
struct VideoGridViewErrorBannerTests {
    @Test func dismissesOnlyForDominantHorizontalFlicksPastThreshold() {
        #expect(VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 100, height: 20)
        ))
        #expect(VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: -100, height: 20)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 99, height: 0)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 140, height: 141)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: -99, height: 0)
        ))
        #expect(!VideoGridView.shouldDismissErrorBanner(
            translation: CGSize(width: 0, height: 120)
        ))
    }

    @Test func dismissesOnlyTheErrorShownWhenTheDragBegan() {
        #expect(VideoGridView.shouldClearErrorBanner(
            currentText: "Original error",
            displayedText: "Original error"
        ))
        #expect(!VideoGridView.shouldClearErrorBanner(
            currentText: "Newer error",
            displayedText: "Original error"
        ))
    }

    @Test func downloadResolvesOnlyUnversionedEntries() {
        let stored = Video(
            id: 42,
            url: "/videos/42",
            title: "Video 42",
            platform: nil,
            sourceKey: nil,
            previewUrl: nil,
            groupID: nil,
            position: nil,
            status: "done",
            errorMsg: nil,
            streamPath: "/videos/42/stream"
        )

        #expect(VideoGridView.downloadVideo(id: 42, versionID: nil, videos: [stored])?.id == 42)
        // An entry left over from a library version has nothing to resolve to.
        #expect(VideoGridView.downloadVideo(id: 42, versionID: 3, videos: [stored]) == nil)
    }
}
