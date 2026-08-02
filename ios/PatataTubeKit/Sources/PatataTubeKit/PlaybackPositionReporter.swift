import Foundation

public protocol PositionReporting: Sendable {
    /// `force` bypasses the interval throttle for lifecycle transitions where
    /// there may be no later opportunity to save.
    func record(id: Int, secs: Double, duration: Double?, force: Bool) async
    func flushPending() async
}

/// Sends playback positions to the server, throttled, with a local mirror.
///
/// It never throws into the playback path. Failed writes remain pending in the
/// local store for a later `flushPending()` attempt.
public actor PlaybackPositionReporter: PositionReporting {
    private let api: any VideoAPI
    private let store: ResumePositionStore
    private let minimumIntervalSecs: Double
    private let endWindowSecs: Double
    private let now: @Sendable () -> Date
    private var lastSentAt: [Int: Date] = [:]

    public init(
        api: any VideoAPI,
        store: ResumePositionStore,
        minimumIntervalSecs: Double = 10,
        endWindowSecs: Double = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.store = store
        self.minimumIntervalSecs = minimumIntervalSecs
        self.endWindowSecs = endWindowSecs
        self.now = now
    }

    public func record(id: Int, secs: Double, duration: Double?, force: Bool) async {
        let value = Self.effectiveSecs(secs: secs, duration: duration, endWindowSecs: endWindowSecs)
        let generation = store.setLocal(value, for: id)

        let timestamp = now()
        if !force, let last = lastSentAt[id], timestamp.timeIntervalSince(last) < minimumIntervalSecs {
            return
        }
        lastSentAt[id] = timestamp
        await send(id: id, secs: value, generation: generation)
    }

    public func flushPending() async {
        for pending in store.pendingWithGenerations() {
            await send(id: pending.id, secs: pending.secs, generation: pending.generation)
        }
    }

    private func send(id: Int, secs: Double, generation: ResumePositionGeneration) async {
        do {
            try await api.savePosition(
                id: id,
                secs: secs,
                destinationServerIdentity: generation.serverIdentity
            )
            store.markSynced(id: id, generation: generation)
            DevLog.event(.net, "position saved", [
                "video_id": "\(id)",
                "secs": "\(Int(secs))",
                "status": "ok",
            ])
        } catch {
            DevLog.event(.error, "position save failed", [
                "video_id": "\(id)",
                "status": "failed",
            ])
        }
    }

    /// Within the final `endWindowSecs` counts as watched and resets resume.
    static func effectiveSecs(secs: Double, duration: Double?, endWindowSecs: Double) -> Double {
        guard let duration, duration > 0 else { return max(0, secs) }
        if secs >= duration - endWindowSecs { return 0 }
        return max(0, secs)
    }
}
