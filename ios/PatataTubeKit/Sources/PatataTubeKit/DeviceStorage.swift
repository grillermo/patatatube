import Foundation

/// Free-space queries for the volume backing a given path.
public enum DeviceStorage {
    /// Bytes available for "important" usage — the number iOS actually lets an
    /// app consume, which is smaller than the raw free space on the volume.
    ///
    /// Returns `nil` rather than throwing: every caller here is advisory, and a
    /// failed lookup must never block the action it is describing.
    ///
    /// `DevLog.swift` reads the same key, but that call site is compiled out
    /// unless `DEVLOG` is defined, so it cannot be reused.
    public static func availableBytes(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return available
    }
}
