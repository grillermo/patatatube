import Foundation
import Observation
import PatataTubeKit

struct DownloadButtonIdentity: Hashable, Sendable {
    let videoID: Int
    let versionID: Int?
    let audioLanguage: String?
}

@MainActor
@Observable
final class DownloadButtonState {
    enum Phase: Equatable {
        case idle
        case loading
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var observedCacheState: CacheState?
    private(set) var progress: Double = 0
    private(set) var activeAttemptID: UUID?

    init(initialCacheState: CacheState = .notCached) {
        observe(initialCacheState)
    }

    var effectiveState: CacheState {
        let observedState = observedCacheState ?? .notCached
        switch phase {
        case .loading:
            if case .downloading = observedState { return observedState }
            return .downloading(progress)
        case .done:
            return .cached
        case .idle:
            return observedState
        }
    }

    var clampedProgress: Double {
        let value: Double
        if case .downloading(let progress) = effectiveState {
            value = progress
        } else {
            value = self.progress
        }
        return min(max(value, 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = effectiveState { return true }
        return false
    }

    @discardableResult
    func begin(attemptID: UUID = UUID()) -> UUID {
        activeAttemptID = attemptID
        phase = .loading
        observedCacheState = .downloading(0)
        progress = 0
        return attemptID
    }

    func finish(attemptID: UUID, succeeded: Bool) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        phase = succeeded ? .done : .idle
        observedCacheState = succeeded ? .cached : .notCached
        progress = succeeded ? 1 : 0
    }

    func cancel() {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = .notCached
        progress = 0
    }

    func reset(to cacheState: CacheState) {
        activeAttemptID = nil
        phase = .idle
        observedCacheState = nil
        progress = 0
        observe(cacheState)
    }

    func observe(_ cacheState: CacheState) {
        observedCacheState = cacheState
        switch cacheState {
        case .downloading(let progress):
            self.progress = progress
        case .cached:
            progress = 1
        case .notCached:
            if phase == .idle { progress = 0 }
        }
    }
}
