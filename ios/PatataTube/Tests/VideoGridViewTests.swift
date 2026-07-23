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

    @Test func unversionedDownloadResolvesUnversionedPlaybackIdentity() {
        let stored = Video(
            id: 42,
            url: "/videos/42",
            title: "Video 42",
            platform: nil,
            sourceKey: nil,
            previewUrl: nil,
            classification: "movies",
            position: nil,
            status: "done",
            errorMsg: nil,
            streamPath: "/videos/42/stream",
            chosenVersionId: 3,
            versions: [
                VideoVersion(
                    id: 3,
                    label: "Chosen",
                    status: "done",
                    isChosen: true
                )
            ]
        )

        let resolved = VideoGridView.downloadVideo(
            id: stored.id,
            versionID: nil,
            videos: [stored]
        )

        #expect(resolved?.id == stored.id)
        #expect(resolved?.chosenVersionId == nil)
        #expect(resolved?.versions.allSatisfy { !$0.isChosen } == true)
    }
}
