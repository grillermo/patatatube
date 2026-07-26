import AVFoundation
import Foundation
@testable import PatataTubeKit

/// Scriptable stand-in for `HLSDownloadEngine`. Records requests and lets a test
/// emit progress/terminal events synchronously.
final class FakeHLSDownloader: HLSDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (HLSDownloadEvent) -> Void)?
    private var running: Set<String> = []
    private(set) var requests: [HLSDownloadRequest] = []
    private(set) var cancelledKeys: [String] = []
    var restoreCallCount = 0
    /// Asset handed back by `start`; nil simulates a session that refused the task.
    var assetToReturn: AVURLAsset? = AVURLAsset(url: URL(string: "https://fake.test/m.m3u8")!)

    func start(_ request: HLSDownloadRequest) -> AVURLAsset? {
        lock.withLock {
            requests.append(request)
            running.insert(request.cacheKey)
        }
        return assetToReturn
    }

    func cancel(cacheKey: String) {
        lock.withLock {
            cancelledKeys.append(cacheKey)
            running.remove(cacheKey)
        }
        emit(.cancelled(cacheKey: cacheKey))
    }

    func isRunning(cacheKey: String) -> Bool {
        lock.withLock { running.contains(cacheKey) }
    }

    func runningKeys() -> Set<String> {
        lock.withLock { running }
    }

    func restoreTasks() async {
        lock.withLock { restoreCallCount += 1 }
    }

    func setEventHandler(_ handler: @escaping @Sendable (HLSDownloadEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    // MARK: Test drivers

    func emitProgress(cacheKey: String, fraction: Double, bytes: Int64 = 1_024) {
        emit(.progress(cacheKey: cacheKey, fraction: fraction, transferredBytes: bytes))
    }

    func emitFinished(cacheKey: String) {
        lock.withLock { running.remove(cacheKey) }
        emit(.finished(cacheKey: cacheKey))
    }

    func emitFailure(cacheKey: String, error: Error) {
        lock.withLock { running.remove(cacheKey) }
        emit(.failed(cacheKey: cacheKey, error: error))
    }

    private func emit(_ event: HLSDownloadEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }
}
