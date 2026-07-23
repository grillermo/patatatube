import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

private func sampleVideo(id: Int) -> Video {
    Video(
        id: id,
        url: "/videos/\(id)",
        title: "Video \(id)",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        classification: "movies",
        position: id,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/\(id)/stream"
    )
}

@Suite("Downloads view")
@MainActor
struct DownloadsViewTests {
    @Test func rateFormatterUsesCalculatingKilobytesAndMegabytes() {
        #expect(DownloadRateFormatter.text(bytesPerSecond: nil) == "Calculating…")
        #expect(DownloadRateFormatter.text(bytesPerSecond: 12_000) == "12 KB/s")
        #expect(DownloadRateFormatter.text(bytesPerSecond: 2_500_000) == "2.5 MB/s")
    }

    @Test func activeRowShowsRateAndCancelInvokesIdentity() async throws {
        var cancelled: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 7,
            versionID: 2,
            progress: 0.5,
            transferredByteCount: 5_000,
            totalByteCount: 10_000,
            bytesPerSecond: 1_500
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = $0.id },
            onPlay: { _ in }
        )

        let inspected = try sut.inspect()
        #expect(try inspected.find(text: "1.5 KB/s").string() == "1.5 KB/s")
        try inspected.find(button: "Cancel").tap()
        #expect(cancelled == activity.id)
    }

    @Test func completedRowPlaysAndEmptyViewOmitsBothSections() async throws {
        var played: Int?
        let completion = DownloadCompletion(videoID: 8, versionID: nil, completedAt: .now)
        let recent = DownloadsView(
            active: { [] },
            recent: { [completion] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { played = $0.id }
        )
        try recent.inspect().find(button: "Video 8").tap()
        #expect(played == 8)

        let empty = DownloadsView(
            active: { [] },
            recent: { [] },
            video: { _, _ in nil },
            onCancel: { _ in },
            onPlay: { _ in }
        )
        #expect((try? empty.inspect().find(text: "In Progress")) == nil)
        #expect((try? empty.inspect().find(text: "Recently Completed")) == nil)
    }
}
