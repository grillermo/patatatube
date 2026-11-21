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
        groupID: nil,
        position: id,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/\(id)/stream"
    )
}

@Suite("Downloads view")
@MainActor
struct DownloadsViewTests {
    @Test func theMenuCancelsWithTheDownloadIdentity() async throws {
        var cancelled: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 7,
            versionID: 2,
            progress: 0.5,
            transferredByteCount: 5_000,
            totalByteCount: 10_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = $0.id },
            onPlay: { _ in }
        )
        .environmentObject(AppModel())

        try sut.inspect().find(button: "Cancel download").tap()
        #expect(cancelled == activity.id)
    }

    @Test func versionedActionsKeepTheDownloadIdentity() throws {
        let activity = DownloadActivity(
            videoID: 12,
            versionID: 99,
            progress: 0.2,
            transferredByteCount: 200,
            totalByteCount: 1_000
        )
        var cancelled: (Int, Int?)?
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { cancelled = ($0.videoID, $0.versionID) },
            onPlay: { _ in }
        )
        .environmentObject(AppModel())

        try sut.inspect().find(button: "Cancel download").tap()
        #expect(cancelled?.0 == 12)
        #expect(cancelled?.1 == 99)
    }

    @Test func aLiveRowOffersPauseAndInvokesIt() throws {
        var paused: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 4, versionID: nil, progress: 0.3,
            transferredByteCount: 300, totalByteCount: 1_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            onPause: { paused = $0.id }
        )
        .environmentObject(AppModel())

        #expect((try? sut.inspect().find(button: "Resume")) == nil)
        try sut.inspect().find(button: "Pause").tap()
        #expect(paused == "4")
    }

    @Test func aPausedRowOffersResumeAndLabelsItself() throws {
        var resumed: DownloadActivity.ID?
        let activity = DownloadActivity(
            videoID: 4, versionID: nil, progress: 0.3,
            transferredByteCount: 300, totalByteCount: 1_000,
            isPaused: true
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            onResume: { resumed = $0.id }
        )
        .environmentObject(AppModel())

        #expect((try? sut.inspect().find(button: "Pause")) == nil)
        #expect(throws: Never.self) { try sut.inspect().find(text: "Paused") }
        try sut.inspect().find(button: "Resume").tap()
        #expect(resumed == "4")
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
        .environmentObject(AppModel())
        try recent.inspect().find(button: "Video 8").tap()
        #expect(played == 8)

        let empty = DownloadsView(
            active: { [] },
            recent: { [] },
            video: { _, _ in nil },
            onCancel: { _ in },
            onPlay: { _ in }
        )
        .environmentObject(AppModel())
        #expect((try? empty.inspect().find(text: "In Progress")) == nil)
        #expect((try? empty.inspect().find(text: "Recently Completed")) == nil)
    }

    @Test func inProgressHeaderRendersWithActiveDownloads() throws {
        let activity = DownloadActivity(
            videoID: 3,
            versionID: nil,
            progress: 0.1,
            transferredByteCount: 100,
            totalByteCount: 1_000
        )
        let sut = DownloadsView(
            active: { [activity] },
            recent: { [] },
            video: { id, _ in sampleVideo(id: id) },
            onCancel: { _ in },
            onPlay: { _ in },
            byteCount: { 4_000_000 }
        )
        .environmentObject(AppModel())

        #expect(throws: Never.self) { try sut.inspect().find(text: "In Progress") }
    }
}
