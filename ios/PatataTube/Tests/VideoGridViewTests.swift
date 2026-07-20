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
}
