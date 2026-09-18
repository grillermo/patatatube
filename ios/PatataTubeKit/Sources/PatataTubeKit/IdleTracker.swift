import Foundation

/// When the user last had the app in front of them — or last heard it.
///
/// "Engaged" means the app was active, or something was playing (the player
/// and the audio queue bump it on their periodic ticks, which keep firing in
/// the background). Coming back after `threshold` without either means the
/// last session is over: whatever was on screen is dropped rather than resumed
/// (see `AppModel.resetAfterIdle`).
///
/// Persisted, so a cold launch after the process was killed is judged the same
/// way as a return from the background.
public final class IdleTracker: @unchecked Sendable {
    public static let defaultThreshold: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private let key: String
    private let threshold: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        defaults: UserDefaults = .standard,
        key: String = "lastEngagedAt",
        threshold: TimeInterval = IdleTracker.defaultThreshold,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.key = key
        self.threshold = threshold
        self.now = now
    }

    public var lastEngagedAt: Date? {
        let stored = defaults.double(forKey: key)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    public func markEngaged() {
        defaults.set(now().timeIntervalSince1970, forKey: key)
    }

    /// True only past the threshold. A first launch (nothing recorded) is not
    /// stale: there is no previous session to drop.
    public func isStale() -> Bool {
        guard let last = lastEngagedAt else { return false }
        return now().timeIntervalSince(last) > threshold
    }
}

/// Whether a video's position survives an idle reset. The same rule
/// `ResumeDecision` uses to decide whether a stored position is offered at all.
public func remembersPosition(_ video: Video) -> Bool {
    video.plexKind != nil || video.rememberPosition
}
