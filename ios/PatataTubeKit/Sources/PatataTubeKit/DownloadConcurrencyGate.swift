import Foundation

/// Caps how many downloads run at once, queueing the rest FIFO. Injected into
/// `CacheManager` so tests can substitute a spy (mirrors `cancellationFence`).
protocol DownloadConcurrencyGating: Sendable {
    func acquire() async
    func release()
    func setLimit(_ n: Int)
    var currentLimit: Int { get }
}

/// FIFO counting semaphore. `acquire` suspends when no permit is free; `release`
/// hands a freed permit to the oldest waiter, or credits it back if none wait.
final class DownloadConcurrencyGate: DownloadConcurrencyGating, @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var currentLimit: Int {
        lock.withLock { limit }
    }

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted: Bool = lock.withLock {
                if active < limit {
                    active += 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if granted { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            active = max(active - 1, 0)
            if active < limit, !waiters.isEmpty {
                active += 1
                return waiters.removeFirst()
            }
            return nil
        }
        next?.resume()
    }

    func setLimit(_ n: Int) {
        let newLimit = max(n, 1)
        let toWake: [CheckedContinuation<Void, Never>] = lock.withLock {
            limit = newLimit
            var woken: [CheckedContinuation<Void, Never>] = []
            while active < limit, !waiters.isEmpty {
                active += 1
                woken.append(waiters.removeFirst())
            }
            return woken
        }
        toWake.forEach { $0.resume() }
    }
}
