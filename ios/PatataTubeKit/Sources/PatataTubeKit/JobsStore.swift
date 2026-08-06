import Foundation
import Observation

/// Polls GET /api/jobs while any view needs it, and answers "what is the server
/// doing with this video right now?".
///
/// Single source for both the download button's ring and the Downloads view's
/// Converting section, so the same number never gets fetched two ways. The loop
/// only runs while something is subscribed -- an idle Downloads tab costs
/// nothing.
@MainActor
@Observable
public final class JobsStore {
    public private(set) var snapshot: JobsSnapshot = .empty

    private let api: JobsAPI
    private let pollIntervalSeconds: Double
    private let sleep: @Sendable (Duration) async throws -> Void
    private var subscriberCount = 0
    private var pollTask: Task<Void, Never>?

    public init(
        api: JobsAPI,
        pollIntervalSeconds: Double = 2.0,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.pollIntervalSeconds = pollIntervalSeconds
        self.sleep = sleep
    }

    public func subscribe() {
        subscriberCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                do {
                    try await self.sleep(.seconds(self.pollIntervalSeconds))
                } catch {
                    return
                }
            }
        }
    }

    public func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// A failed poll leaves the previous snapshot in place: a dropped request
    /// should not blank out a ring that is mid-conversion.
    public func refreshNow() async {
        guard let fresh = try? await api.jobs() else { return }
        snapshot = fresh
    }

    /// A running job whose ffmpeg has not reported yet reads as `.queued` so the
    /// UI keeps spinning instead of flashing 0%.
    public func state(videoID: Int) -> ConversionState? {
        if let running = snapshot.running.first(where: { $0.videoID == videoID }) {
            if let progress = running.progress, progress > 0 { return .running(progress) }
            return .queued
        }
        if snapshot.queued.contains(where: { $0.videoID == videoID }) { return .queued }
        return nil
    }
}
