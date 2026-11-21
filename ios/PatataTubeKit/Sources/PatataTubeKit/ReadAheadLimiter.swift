import Foundation

/// Keeps a playback fetcher at most `lead` bytes ahead of what its reader has
/// sent. AVPlayer asks for the whole file and reads slowly; without this,
/// every tapped video would download completely.
final class ReadAheadLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let lead: Int64
    private var position: Int64
    private var isCancelled = false
    private var waiters: [UUID: (nextByte: Int64, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(lead: Int64, position: Int64) {
        self.lead = lead
        self.position = position
    }

    func wouldWait(nextByte: Int64) -> Bool {
        lock.withLock { nextByte - position > lead }
    }

    /// The reader has sent everything before `newPosition`.
    func advance(to newPosition: Int64) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            position = max(position, newPosition)
            let ids = waiters.filter { $0.value.nextByte - position <= lead }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once fetching `nextByte` keeps within the lead. Throws
    /// `CancellationError` when cancelled or when the limiter is.
    func waitForRoom(nextByte: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let verdict = lock.withLock { () -> Result<Void, Error>? in
                    if isCancelled || Task.isCancelled { return .failure(CancellationError()) }
                    if nextByte - position <= lead { return .success(()) }
                    waiters[id] = (nextByte, continuation)
                    return nil
                }
                if let verdict { continuation.resume(with: verdict) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func cancel() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isCancelled = true
            defer { waiters.removeAll() }
            return waiters.values.map(\.continuation)
        }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}
