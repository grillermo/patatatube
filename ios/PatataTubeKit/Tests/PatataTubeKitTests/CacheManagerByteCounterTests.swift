import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Cache manager cumulative byte counter")
struct CacheManagerByteCounterTests {
    private func makeManager() -> CacheManager {
        CacheManager(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("byte-counter-\(UUID().uuidString)"),
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    @Test func accumulatesProgressAcrossDownloads() {
        let manager = makeManager()
        #expect(manager.downloadedByteCount() == 0)

        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 400)
        #expect(manager.downloadedByteCount() == 400)

        manager.updateExternalActivity(key: "1", completedUnits: 900)
        #expect(manager.downloadedByteCount() == 900)
    }

    @Test func aFinishedDownloadDoesNotSubtractItsBytes() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 400)
        manager.endExternalActivity(key: "1")
        #expect(manager.activeDownloads().isEmpty)
        #expect(manager.downloadedByteCount() == 400)

        manager.beginExternalActivity(key: "2", videoId: 2, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "2", completedUnits: 300)
        #expect(manager.downloadedByteCount() == 700)
    }

    @Test func aCancelledDownloadDoesNotSubtractItsBytes() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 250)
        manager.cancelExternalActivity(key: "1")
        #expect(manager.downloadedByteCount() == 250)
    }

    @Test func aRegressingProgressReportAddsNothing() {
        // A restarted transfer can report fewer completed units than before.
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.updateExternalActivity(key: "1", completedUnits: 600)
        manager.updateExternalActivity(key: "1", completedUnits: 100)
        #expect(manager.downloadedByteCount() == 600)
    }

    @Test func activeDownloadsStillReportsEveryInFlightTransfer() {
        let manager = makeManager()
        manager.beginExternalActivity(key: "1", videoId: 1, versionId: nil, totalUnits: 1_000)
        manager.beginExternalActivity(key: "2", videoId: 2, versionId: 7, totalUnits: 2_000)
        manager.updateExternalActivity(key: "2", completedUnits: 1_000)

        let active = manager.activeDownloads()
        #expect(active.count == 2)
        #expect(active.map(\.videoID).sorted() == [1, 2])
        #expect(active.first { $0.videoID == 2 }?.progress == 0.5)
    }
}
