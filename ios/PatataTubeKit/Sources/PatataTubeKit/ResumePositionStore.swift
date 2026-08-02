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
    private var generations: [Int: UInt64] = [:]

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

    /// Stores a value and returns its in-process generation for conditional
    /// acknowledgement after an asynchronous API write.
    @discardableResult
    public func setLocal(_ secs: Double, for id: Int) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let generation = generations[id, default: 0] &+ 1
        generations[id] = generation
        defaults.set(max(0, secs), forKey: valueKey(id))
        defaults.set(true, forKey: pendingKey(id))
        return generation
    }

    public func markSynced(id: Int) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: pendingKey(id))
    }

    /// Clears a pending marker only when no newer local write superseded the
    /// value that the caller sent.
    public func markSynced(id: Int, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard generations[id, default: 0] == generation else { return }
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

    /// Pending values with their in-process generations, for safe async
    /// acknowledgements. Existing persisted values have generation zero until
    /// a newer local write occurs in this process.
    public func pendingWithGenerations() -> [(id: Int, secs: Double, generation: UInt64)] {
        lock.lock(); defer { lock.unlock() }
        var result: [(id: Int, secs: Double, generation: UInt64)] = []
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix("resumeSecsPending.") {
            let suffix = String(key.dropFirst("resumeSecsPending.".count))
            guard let id = Int(suffix), defaults.bool(forKey: key) else { continue }
            result.append((id, defaults.double(forKey: valueKey(id)), generations[id, default: 0]))
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
