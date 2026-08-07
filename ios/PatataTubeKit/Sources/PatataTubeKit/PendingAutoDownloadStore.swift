import Foundation

/// Video ids whose conversion **this device** asked for and that should start
/// downloading by themselves once the server is done converting them.
///
/// Tapping play on an unconverted library row triggers a conversion without a
/// download, and a conversion started on the web UI or another device must not
/// pull bytes onto this one — so the intent is recorded here rather than
/// inferred from `GET /api/jobs`. Persisted because a conversion easily outlives
/// the app process that started it; the entry is dropped as soon as the
/// download is attempted.
public final class PendingAutoDownloadStore: @unchecked Sendable {
    public static let defaultsKey = "pendingAutoDownloads"
    /// Insertion-ordered, oldest evicted first. A stale id whose conversion
    /// never finished would otherwise sit here forever.
    public static let capacity = 200

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var order: [Int] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = (defaults.array(forKey: Self.defaultsKey) as? [Int]) ?? []
    }

    public var ids: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(order)
    }

    public func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return order.contains(id)
    }

    public func add(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > Self.capacity {
            order.removeFirst(order.count - Self.capacity)
        }
        persist()
    }

    public func remove(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard order.contains(id) else { return }
        order.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        defaults.set(order, forKey: Self.defaultsKey)
    }
}
