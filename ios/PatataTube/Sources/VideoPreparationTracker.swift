import Observation

@MainActor
@Observable
final class VideoPreparationTracker {
    private var activeCounts: [Int: Int] = [:]

    func isPreparing(videoID: Int) -> Bool {
        activeCounts[videoID, default: 0] > 0
    }

    func begin(videoID: Int) {
        activeCounts[videoID, default: 0] += 1
    }

    func end(videoID: Int) {
        guard let count = activeCounts[videoID] else { return }
        if count <= 1 {
            activeCounts.removeValue(forKey: videoID)
        } else {
            activeCounts[videoID] = count - 1
        }
    }

    func track<T>(
        videoID: Int,
        operation: () async throws -> T
    ) async rethrows -> T {
        begin(videoID: videoID)
        defer { end(videoID: videoID) }
        return try await operation()
    }

    func trackIfIdle<T>(
        videoID: Int,
        operation: () async throws -> T
    ) async rethrows -> T? {
        guard !isPreparing(videoID: videoID) else { return nil }
        return try await track(videoID: videoID, operation: operation)
    }
}
