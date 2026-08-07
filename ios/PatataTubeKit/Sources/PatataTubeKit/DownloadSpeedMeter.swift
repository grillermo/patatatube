import Foundation

/// Aggregate download throughput over a sliding time window.
///
/// Fed with a **monotonic** cumulative byte count (see
/// `CacheManager.downloadedByteCount()`): a snapshot sum over the active
/// downloads would drop when a transfer finishes and its bytes leave the set,
/// which reads as a negative rate. A counter that only grows turns a finished
/// download into a flat stretch instead, so the average decays across the
/// window rather than lying.
///
/// Owns no clock and does no I/O — the caller supplies each sample's date,
/// which is what makes it testable without sleeping.
public struct DownloadSpeedMeter: Sendable {
    private struct Sample {
        let date: Date
        let byteCount: Int64
    }

    private let window: TimeInterval
    private let minimumSpan: TimeInterval
    private var samples: [Sample] = []

    /// - Parameters:
    ///   - window: how far back the average reaches.
    ///   - minimumSpan: the shortest span that yields a rate at all. Below it
    ///     the divisor is small enough that one sample's jitter dominates.
    public init(window: TimeInterval = 5, minimumSpan: TimeInterval = 1) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    public mutating func record(byteCount: Int64, at date: Date) {
        samples.append(Sample(date: date, byteCount: byteCount))
        let cutoff = date.addingTimeInterval(-window)
        // Retain the sample that straddles the cutoff, so the measured span
        // stays close to a full window instead of collapsing to the newest
        // few samples.
        while samples.count > 1, samples[1].date <= cutoff {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double? {
        guard let oldest = samples.first, let newest = samples.last else { return nil }
        let span = newest.date.timeIntervalSince(oldest.date)
        guard span >= minimumSpan else { return nil }
        return Double(newest.byteCount - oldest.byteCount) / span
    }

    /// Decimal megabytes per second to one decimal place, e.g. `"12.4 MB/s"`.
    public var formattedRate: String? {
        guard let bytesPerSecond else { return nil }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
