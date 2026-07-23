import Foundation
import Testing
@testable import PatataTubeKit

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("download-activity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Download activity")
struct DownloadActivityTests {
    @Test func aggregateSamplesProduceOnePerDownloadRate() {
        var accumulator = DownloadActivityAccumulator(
            videoID: 7,
            versionID: 2,
            totalByteCount: 10_000,
            now: Date(timeIntervalSinceReferenceDate: 10)
        )
        accumulator.record(
            transferredByteCount: 2_000,
            progress: 0.2,
            now: Date(timeIntervalSinceReferenceDate: 11)
        )
        accumulator.record(
            transferredByteCount: 5_000,
            progress: 0.5,
            now: Date(timeIntervalSinceReferenceDate: 13)
        )

        #expect(accumulator.activity.transferredByteCount == 5_000)
        #expect(accumulator.activity.bytesPerSecond == 1_500)
        #expect(accumulator.activity.progress == 0.5)
    }

    @Test func resumedBytesDoNotInflateTheNextRateSample() {
        let resumedAt = Date(timeIntervalSinceReferenceDate: 10)
        var accumulator = DownloadActivityAccumulator(
            videoID: 7,
            versionID: 2,
            totalByteCount: 10_000,
            now: resumedAt
        )
        accumulator.establishResumeSamplingBaseline(
            totalBytesWritten: 5_000,
            bytesWritten: 1_000
        )
        accumulator.record(
            transferredByteCount: 5_000,
            progress: 0.5,
            now: Date(timeIntervalSinceReferenceDate: 12)
        )

        #expect(accumulator.activity.bytesPerSecond == 500)
    }

    @Test func multiplexedSegmentSamplesUseTheAggregateByteCountForRate() {
        var accumulator = DownloadActivityAccumulator(
            videoID: 7,
            versionID: 2,
            totalByteCount: 10_000,
            now: Date(timeIntervalSinceReferenceDate: 10)
        )

        // Segment 0 reports first; segment 1 then reports while it remains active.
        accumulator.record(
            transferredByteCount: 1_000,
            progress: 0.1,
            now: Date(timeIntervalSinceReferenceDate: 11)
        )
        accumulator.record(
            transferredByteCount: 3_000,
            progress: 0.3,
            now: Date(timeIntervalSinceReferenceDate: 12)
        )

        #expect(accumulator.activity.transferredByteCount == 3_000)
        // Averaged across the 2.5s window: 3_000 bytes over t10→t12 = 1_500 B/s.
        #expect(accumulator.activity.bytesPerSecond == 1_500)
    }

    @Test func rateAveragesOverTheTrailingWindowAndDropsStaleSamples() {
        var accumulator = DownloadActivityAccumulator(
            videoID: 7,
            versionID: 2,
            totalByteCount: 100_000,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
        // A fast early burst 3s before the last sample must fall out of the 2.5s window.
        accumulator.record(
            transferredByteCount: 9_000,
            progress: 0.09,
            now: Date(timeIntervalSinceReferenceDate: 1)
        )
        // Steady 1_000 B/s from t2 onward.
        accumulator.record(
            transferredByteCount: 10_000,
            progress: 0.1,
            now: Date(timeIntervalSinceReferenceDate: 2)
        )
        accumulator.record(
            transferredByteCount: 12_000,
            progress: 0.12,
            now: Date(timeIntervalSinceReferenceDate: 4)
        )

        // Window at t4 spans back to t1.5, so only t2→t4 counts: 2_000 / 2 = 1_000 B/s.
        #expect(accumulator.activity.bytesPerSecond == 1_000)
    }

    @Test func historyKeepsNewestThreeAndReloads() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store = DownloadCompletionHistoryStore(root: root)
        for id in 1...4 {
            store.record(DownloadCompletion(
                videoID: id,
                versionID: nil,
                completedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(id))
            ))
        }
        let reloaded = DownloadCompletionHistoryStore(root: root)
        #expect(reloaded.entries.map(\.videoID) == [4, 3, 2])
    }

    @Test func historyPersistsTruncationOfExistingEntries() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = (1...4).map {
            DownloadCompletion(
                videoID: $0,
                versionID: nil,
                completedAt: Date(timeIntervalSinceReferenceDate: TimeInterval($0))
            )
        }
        let url = root.appendingPathComponent("download-completions.json")
        try JSONEncoder().encode(entries).write(to: url)

        _ = DownloadCompletionHistoryStore(root: root)

        let persisted = try JSONDecoder().decode(
            [DownloadCompletion].self,
            from: Data(contentsOf: url)
        )
        #expect(persisted.map(\.videoID) == [4, 3, 2])
    }

    @Test func historyPrunesEntriesWithoutLocalFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let completion = DownloadCompletion(videoID: 9, versionID: 1, completedAt: .now)
        var store = DownloadCompletionHistoryStore(root: root)
        store.record(completion)
        #expect(store.prune { _ in false }.isEmpty)
    }

}
