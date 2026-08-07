import PatataTubeKit
import SwiftUI
import Testing
import ViewInspector
@testable import PatataTube

private struct StubJobsAPI: JobsAPI {
    let snapshot: JobsSnapshot

    func jobs() async throws -> JobsSnapshot { snapshot }
}

private func sampleVideo(id: Int) -> Video {
    Video(
        id: id,
        url: "/videos/\(id)",
        title: "Video \(id)",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        groupID: nil,
        plexKind: .movies,
        position: id,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/\(id)/stream"
    )
}

@Suite("Downloads view")
@MainActor
struct DownloadsViewTests {
    @Test func activeRowShowsProgressAndCancelInvokesIdentity() async throws {
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

        let inspected = try sut.inspect()
        try inspected.find(button: "Cancel").tap()
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

        try sut.inspect().find(button: "Cancel").tap()
        #expect(cancelled?.0 == 12)
        #expect(cancelled?.1 == 99)
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

/// Hosts a `DownloadsView` with a `JobsStore` in its environment and resolves
/// once SwiftUI has actually installed that environment -- reading
/// `@Environment(JobsStore.self)` from an un-hosted view (plain `sut.inspect()`,
/// no `ViewHosting.host`) returns the default `nil`, so it can never see the
/// store passed via `.environment(store)`. Mirrors
/// `hostedDownloadButtonWithJobsStore` in DownloadButtonTests.swift.
@MainActor
private func hostedDownloadsView(
    store: JobsStore,
    function: String = #function
) async throws -> DownloadsView {
    return try await withCheckedThrowingContinuation { continuation in
        // Nil, not sampleVideo(id:): a converting job's video may not be in the
        // locally-loaded grid yet (still queued server-side), which is exactly
        // the case convertingRow's `job.title` fallback exists for.
        var view = DownloadsView(
            active: { [] },
            recent: { [] },
            video: { _, _ in nil },
            onCancel: { _ in },
            onPlay: { _ in }
        )
        _ = view.on(\.didAppear, function: function) { hosted in
            do {
                var resolved = try hosted.actualView()
                resolved.didAppear = nil
                continuation.resume(returning: resolved)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        ViewHosting.host(
            view: view.environment(store).environmentObject(AppModel()),
            function: function
        )
    }
}

@Suite("Downloads view converting section", .serialized)
@MainActor
struct DownloadsViewConvertingTests {
    @Test func listsConvertingJobsWithTheirPercent() async throws {
        let store = JobsStore(api: StubJobsAPI(snapshot: JobsSnapshot(
            running: [ConversionJob(id: 1, videoID: 7, versionID: nil, kind: "convert",
                                    progress: 0.47, title: "Blade Runner", showTitle: nil)],
            queued: [ConversionJob(id: 2, videoID: 8, versionID: nil, kind: "convert",
                                   progress: nil, title: "Dune", showTitle: nil)],
            queuedTotal: 1)))
        await store.refreshNow()
        let sut = try await hostedDownloadsView(store: store)
        defer { ViewHosting.expel() }

        #expect(throws: Never.self) { try sut.inspect().find(text: "Converting") }
        #expect(throws: Never.self) { try sut.inspect().find(text: "47%") }
        #expect(throws: Never.self) { try sut.inspect().find(text: "Dune") }
    }

    @Test func showsTheOverflowCountWhenTheQueueIsCapped() async throws {
        let queued = (1...20).map {
            ConversionJob(id: $0, videoID: $0, versionID: nil, kind: "convert",
                          progress: nil, title: "Video \($0)", showTitle: nil)
        }
        let store = JobsStore(api: StubJobsAPI(snapshot: JobsSnapshot(
            running: [], queued: queued, queuedTotal: 203)))
        await store.refreshNow()
        let sut = try await hostedDownloadsView(store: store)
        defer { ViewHosting.expel() }

        #expect(throws: Never.self) { try sut.inspect().find(text: "+183 more") }
    }

    @Test func hidesTheConvertingSectionWhenNothingIsConverting() async throws {
        let store = JobsStore(api: StubJobsAPI(snapshot: .empty))
        await store.refreshNow()
        let sut = try await hostedDownloadsView(store: store)
        defer { ViewHosting.expel() }

        #expect(throws: (any Error).self) { try sut.inspect().find(text: "Converting") }
    }
}
