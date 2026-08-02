import Foundation

/// Local mirror of the server's resume positions.
///
/// The server is the source of truth, but a device watching a downloaded file
/// on a dead network still has to resume correctly, and a write that failed
/// must not be lost. Every write lands here first and is marked pending until
/// the API accepts it; a pending value outranks whatever the list endpoint
/// last said, because it is strictly newer.
public final class ResumePositionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func valueKey(_ id: Int) -> String { "resumeSecs.\(id)" }
    private func pendingKey(_ id: Int) -> String { "resumeSecsPending.\(id)" }

    public func local(for id: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard defaults.object(forKey: valueKey(id)) != nil else { return nil }
        return defaults.double(forKey: valueKey(id))
    }

    public func setLocal(_ secs: Double, for id: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(max(0, secs), forKey: valueKey(id))
        defaults.set(true, forKey: pendingKey(id))
    }

    public func markSynced(id: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: pendingKey(id))
    }

    /// Ids whose latest local value never reached the server, newest value each.
    public func pending() -> [Int: Double] {
        lock.lock(); defer { lock.unlock() }
        var result: [Int: Double] = [:]
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix("resumeSecsPending.") {
            let suffix = String(key.dropFirst("resumeSecsPending.".count))
            guard let id = Int(suffix), defaults.bool(forKey: key) else { continue }
            result[id] = defaults.double(forKey: valueKey(id))
        }
        return result
    }

    /// The position to actually use: a pending local write wins, otherwise the
    /// server's value.
    public func resolved(server: Double, for id: Int) -> Double {
        lock.lock()
        let isPending = defaults.bool(forKey: pendingKey(id))
        let hasLocal = defaults.object(forKey: valueKey(id)) != nil
        let localValue = defaults.double(forKey: valueKey(id))
        lock.unlock()
        return (isPending && hasLocal) ? localValue : server
    }
}
