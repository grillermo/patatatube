import Foundation

/// `UserDefaults`-backed home for `RestorationState`, in the shape of
/// `WebHistoryStore`: nothing throws, and unreadable storage is treated as no
/// state and overwritten on the next save. A broken blob must never keep the
/// app from launching or from recording fresh state.
///
/// There is deliberately no expiry — a relaunch a week later still restores.
public final class RestorationStore: @unchecked Sendable {
    public static let storageKey = "restorationState"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RestorationState {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public func save(_ state: RestorationState) {
        lock.lock(); defer { lock.unlock() }
        saveLocked(state)
    }

    /// Read-modify-write under one lock, so two edits landing in the same run
    /// loop tick cannot clobber each other.
    public func mutate(_ body: (inout RestorationState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = loadLocked()
        body(&state)
        saveLocked(state)
    }

    private func loadLocked() -> RestorationState {
        guard let data = defaults.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(RestorationState.self, from: data)
        else { return .empty }
        return state
    }

    private func saveLocked(_ state: RestorationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
