import Foundation

/// Runs `operation` over `items` with at most `limit` running at once.
///
/// Seeds `limit` tasks, then replaces each one as it finishes — a sliding
/// window rather than a batch, so a slow item never stalls the others.
///
/// This exists because `CacheManager`'s `DownloadConcurrencyGate` bounds
/// *transfers*, and the work a Download-all does before reaching a transfer
/// (`ensureReady` -> `POST /prepare` -> a 2s poll loop) is not covered by it.
/// Spawning one task per video sent 226 concurrent prepare calls at the server
/// on 2026-07-31 and took the machine down.
///
/// `operation` is `@MainActor` because both call sites are SwiftUI views, and
/// `@Sendable` because `TaskGroup.addTask` requires it. Callers that need to
/// skip items should test inside `operation`, not by pre-filtering `items` —
/// an item can sit queued long enough for its eligibility to change.
@MainActor
public func withBoundedTaskGroup<T: Sendable>(
    limit: Int,
    over items: [T],
    operation: @escaping @MainActor @Sendable (T) async -> Void
) async {
    guard !items.isEmpty else { return }
    let bound = max(limit, 1)

    await withTaskGroup(of: Void.self) { group in
        var next = 0

        while next < items.count, next < bound {
            let item = items[next]
            group.addTask { await operation(item) }
            next += 1
        }

        while await group.next() != nil {
            // Stop seeding on cancellation; the group still awaits whatever is
            // already running when this scope exits.
            if Task.isCancelled { break }
            guard next < items.count else { continue }
            let item = items[next]
            group.addTask { await operation(item) }
            next += 1
        }
    }
}
