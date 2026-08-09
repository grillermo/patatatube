import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager pause")
struct CacheManagerPauseTests {
    fileprivate func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-cache-\(UUID().uuidString)")
    }

    fileprivate func pausedEntry(
        videoID: Int,
        versionID: Int? = nil,
        progress: Double = 0.4
    ) -> PausedDownload {
        PausedDownload(
            videoID: videoID,
            versionID: versionID,
            remoteURL: URL(string: "https://example.com/\(videoID).mp4")!,
            isHLS: false,
            streamCount: 2,
            previewURL: nil,
            showPosterKey: nil,
            showPosterURL: nil,
            progress: progress,
            transferredByteCount: 400,
            totalByteCount: 1_000
        )
    }

    /// Seeds a paused entry on disk, then builds a manager over that root so it
    /// loads the entry at init — the "app was quit while paused" case.
    fileprivate func managerWithPausedEntry(
        _ entry: PausedDownload,
        root: URL
    ) -> CacheManager {
        var store = PausedDownloadStore(root: root)
        store.insert(entry)
        return CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    @Test func pausedEntriesAppearInActiveDownloadsAsPaused() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, versionID: 2), root: root)

        let activities = manager.activeDownloads()
        #expect(activities.count == 1)
        #expect(activities.first?.videoID == 7)
        #expect(activities.first?.versionID == 2)
        #expect(activities.first?.isPaused == true)
        #expect(activities.first?.progress == 0.4)
    }

    @Test func pausedEntriesDoNotMoveTheByteCounter() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        #expect(manager.downloadedByteCount() == 0)
    }

    @Test func aPausedKeyStillReadsAsDownloading() {
        let root = temporaryRoot()
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7, progress: 0.4), root: root)
        guard case .downloading(let progress) = manager.state(for: 7) else {
            Issue.record("expected .downloading, got \(manager.state(for: 7))")
            return
        }
        #expect(progress == 0.4)
    }

    @Test func aPausedEntryWhoseFileLandedIsDropped() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = managerWithPausedEntry(pausedEntry(videoID: 7), root: root)
        try Data("mp4".utf8).write(to: manager.localURL(for: 7))

        #expect(manager.activeDownloads().isEmpty)
        #expect(PausedDownloadStore(root: root).contains("7") == false)
    }
}
