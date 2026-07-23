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
