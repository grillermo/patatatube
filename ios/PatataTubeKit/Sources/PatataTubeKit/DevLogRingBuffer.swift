import Foundation

/// Fixed-capacity FIFO of pending records.
///
/// Overflow drops the **oldest** record and counts it, rather than blocking the
/// producer. That direction matters: the producer is the playback path, and an
/// instrument that applies backpressure to the thing it is measuring produces
/// evidence about itself instead of about the bug. The drop count is surfaced on
/// `drain` so a gap in the log is always visible rather than silent.
///
/// Not thread-safe on its own — `DevLog` serialises access behind a lock.
final class DevLogRingBuffer {
    private var storage: [DevLogRecord?]
    private var head = 0        // next write index
    private var count = 0
    private var dropped: UInt64 = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "DevLogRingBuffer needs a positive capacity")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var pendingCount: Int { count }
    var droppedCount: UInt64 { dropped }

    func append(_ record: DevLogRecord) {
        if count == capacity {
            dropped &+= 1       // head already points at the oldest; overwrite it
        } else {
            count += 1
        }
        storage[head] = record
        head = (head + 1) % capacity
    }

    /// Removes and returns everything pending, oldest first, along with the
    /// number of records dropped since the previous drain (then resets it).
    func drain() -> (records: [DevLogRecord], dropped: UInt64) {
        guard count > 0 || dropped > 0 else { return ([], 0) }

        var out: [DevLogRecord] = []
        out.reserveCapacity(count)
        var index = (head - count + capacity) % capacity
        for _ in 0..<count {
            if let record = storage[index] { out.append(record) }
            storage[index] = nil
            index = (index + 1) % capacity
        }

        let droppedThisDrain = dropped
        head = 0
        count = 0
        dropped = 0
        return (out, droppedThisDrain)
    }
}
