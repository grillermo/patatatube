import Foundation

/// Identifies the exact local write acknowledged by an asynchronous save.
public struct ResumePositionGeneration: Sendable {
    fileprivate let serverIdentity: String
    fileprivate let value: UInt64
}

/// Local mirror of the configured server's resume positions.
///
/// Every key is scoped to a normalized server identity, so changing the API
/// base URL can never send server A's pending row id to server B. A successful
/// write remains authoritative over the currently displayed/cached list until
/// a later successful list fetch supplies a fresh value for that row.
public final class ResumePositionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var serverIdentity: String
    private var generations: [String: UInt64] = [:]

    public init(defaults: UserDefaults = .standard, serverURL: URL? = nil) {
        self.defaults = defaults
        self.serverIdentity = Self.normalizedServerIdentity(serverURL)
    }

    /// Switches reads, writes, and pending enumeration to one server namespace.
    public func useServer(_ serverURL: URL?) {
        lock.lock(); defer { lock.unlock() }
        serverIdentity = Self.normalizedServerIdentity(serverURL)
    }

    public static func normalizedServerIdentity(_ serverURL: URL?) -> String {
        guard let serverURL,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        else { return "unconfigured" }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? serverURL.absoluteString
    }

    private func namespacePrefix(_ identity: String) -> String {
        "resumePosition.\(identity)."
    }

    private func valueKey(_ id: Int, identity: String) -> String {
        "\(namespacePrefix(identity))value.\(id)"
    }

    private func pendingKey(_ id: Int, identity: String) -> String {
        "\(namespacePrefix(identity))pending.\(id)"
    }

    private func awaitingServerKey(_ id: Int, identity: String) -> String {
        "\(namespacePrefix(identity))awaitingServer.\(id)"
    }

    private func generationKey(_ id: Int, identity: String) -> String {
        "\(identity)|\(id)"
    }

    public func local(for id: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let key = valueKey(id, identity: serverIdentity)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    /// Stores a value and returns its server-scoped in-process generation for
    /// conditional acknowledgement after an asynchronous API write.
    @discardableResult
    public func setLocal(_ secs: Double, for id: Int) -> ResumePositionGeneration {
        lock.lock(); defer { lock.unlock() }
        let identity = serverIdentity
        let key = generationKey(id, identity: identity)
        let generation = generations[key, default: 0] &+ 1
        generations[key] = generation
        defaults.set(max(0, secs), forKey: valueKey(id, identity: identity))
        defaults.set(true, forKey: pendingKey(id, identity: identity))
        defaults.removeObject(forKey: awaitingServerKey(id, identity: identity))
        return ResumePositionGeneration(serverIdentity: identity, value: generation)
    }

    public func markSynced(id: Int) {
        lock.lock(); defer { lock.unlock() }
        markSyncedLocked(id: id, identity: serverIdentity)
    }

    /// Clears a pending marker only when no newer local write superseded the
    /// value that the caller sent, and retains local authority until a fresh
    /// server list is reconciled.
    public func markSynced(id: Int, generation: ResumePositionGeneration) {
        lock.lock(); defer { lock.unlock() }
        let key = generationKey(id, identity: generation.serverIdentity)
        guard generations[key, default: 0] == generation.value else { return }
        markSyncedLocked(id: id, identity: generation.serverIdentity)
    }

    private func markSyncedLocked(id: Int, identity: String) {
        defaults.removeObject(forKey: pendingKey(id, identity: identity))
        defaults.set(true, forKey: awaitingServerKey(id, identity: identity))
    }

    /// Ids whose latest local value never reached the current server.
    public func pending() -> [Int: Double] {
        lock.lock(); defer { lock.unlock() }
        return pendingLocked(identity: serverIdentity).reduce(into: [:]) {
            $0[$1.id] = $1.secs
        }
    }

    /// Pending values with server-scoped generations for safe async acks.
    public func pendingWithGenerations() -> [(
        id: Int, secs: Double, generation: ResumePositionGeneration
    )] {
        lock.lock(); defer { lock.unlock() }
        let identity = serverIdentity
        return pendingLocked(identity: identity).map { item in
            let generation = generations[generationKey(item.id, identity: identity), default: 0]
            return (
                item.id,
                item.secs,
                ResumePositionGeneration(serverIdentity: identity, value: generation)
            )
        }
    }

    private func pendingLocked(identity: String) -> [(id: Int, secs: Double)] {
        let prefix = "\(namespacePrefix(identity))pending."
        var result: [(id: Int, secs: Double)] = []
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            guard let id = Int(suffix), defaults.bool(forKey: key) else { continue }
            result.append((id, defaults.double(forKey: valueKey(id, identity: identity))))
        }
        return result
    }

    /// A successful online list response is the next authoritative observation
    /// after a write. It may acknowledge the same value or replace it with a
    /// newer value written by another client. Pending (unsent) values still win.
    public func reconcileFreshServerPositions(_ positions: [Int: Double]) {
        lock.lock(); defer { lock.unlock() }
        let identity = serverIdentity
        for id in positions.keys where !defaults.bool(forKey: pendingKey(id, identity: identity)) {
            defaults.removeObject(forKey: awaitingServerKey(id, identity: identity))
        }
    }

    /// Pending and successfully-sent-but-not-yet-refetched local values outrank
    /// the currently displayed row, which may have come from an offline cache.
    public func resolved(server: Double, for id: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        let identity = serverIdentity
        let valueKey = valueKey(id, identity: identity)
        let hasLocal = defaults.object(forKey: valueKey) != nil
        let isLocallyAuthoritative = defaults.bool(forKey: pendingKey(id, identity: identity))
            || defaults.bool(forKey: awaitingServerKey(id, identity: identity))
        return (hasLocal && isLocallyAuthoritative) ? defaults.double(forKey: valueKey) : server
    }
}
