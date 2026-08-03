import Foundation

/// One-shot permission to apply saved restoration state, scoped to an app
/// launch rather than to a view.
///
/// `VideoGridView`'s restore lives in a `.task`, and SwiftUI restarts a
/// `.task` whenever its view re-enters the hierarchy — which is exactly what
/// dismissing a `fullScreenCover` does. Left ungated, every player dismissal
/// re-ran boot restoration and re-presented the player it had just dismissed
/// (2026-08-02; see `docs/restoration-buggy.md`). The gate has to outlive the
/// view, so it is held by `AppModel`, not by `@State`.
public final class RestorationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// Returns `true` to exactly one caller per launch. Safe to call from any
    /// thread and from overlapping SwiftUI updates.
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    /// Re-arms the gate. Used by the "Clear Restoration" quick action so a
    /// wipe-and-relaunch-free reset behaves like a fresh launch, and by tests.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        claimed = false
    }
}
