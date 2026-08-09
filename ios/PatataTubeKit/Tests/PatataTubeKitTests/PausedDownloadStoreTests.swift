import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Paused download store")
struct PausedDownloadStoreTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-\(UUID().uuidString)")
    }

    private func sample(videoID: Int, versionID: Int? = nil) -> PausedDownload {
        PausedDownload(
            videoID: videoID,
            versionID: versionID,
            remoteURL: URL(string: "https://example.com/\(videoID).mp4")!,
            isHLS: false,
            streamCount: 2,
            previewURL: nil,
            showPosterKey: nil,
            showPosterURL: nil,
            progress: 0.25,
            transferredByteCount: 250,
            totalByteCount: 1_000
        )
    }

    @Test func entriesSurviveANewStoreOnTheSameRoot() {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(sample(videoID: 7, versionID: 2))

        let reopened = PausedDownloadStore(root: root)
        #expect(reopened.entries.count == 1)
        #expect(reopened.contains("7:2"))
        #expect(reopened.entry("7:2")?.progress == 0.25)
        #expect(reopened.entry("7:2")?.streamCount == 2)
    }

    @Test func insertReplacesTheEntryForTheSameKey() {
        var store = PausedDownloadStore(root: temporaryRoot())
        store.insert(sample(videoID: 7))
        var updated = sample(videoID: 7)
        updated = PausedDownload(
            videoID: 7, versionID: nil,
            remoteURL: updated.remoteURL, isHLS: false, streamCount: 2,
            previewURL: nil, showPosterKey: nil, showPosterURL: nil,
            progress: 0.9, transferredByteCount: 900, totalByteCount: 1_000
        )
        store.insert(updated)

        #expect(store.entries.count == 1)
        #expect(store.entry("7")?.progress == 0.9)
    }

    @Test func removeAndRemoveAllClearEntriesAndPersist() {
        let root = temporaryRoot()
        var store = PausedDownloadStore(root: root)
        store.insert(sample(videoID: 1))
        store.insert(sample(videoID: 2))
        store.remove("1")
        #expect(PausedDownloadStore(root: root).contains("1") == false)
        #expect(PausedDownloadStore(root: root).contains("2"))

        store.removeAll()
        #expect(PausedDownloadStore(root: root).entries.isEmpty)
    }

    @Test func aCorruptFileLoadsAsEmpty() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("paused-downloads.json")
        )
        #expect(PausedDownloadStore(root: root).entries.isEmpty)
    }

    @Test func idMatchesTheCacheKeyFormat() {
        #expect(sample(videoID: 7, versionID: 2).id == "7:2")
        #expect(sample(videoID: 7).id == "7")
    }
}
