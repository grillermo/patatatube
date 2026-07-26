import Foundation

/// Sorted, disjoint, non-adjacent set of inclusive byte runs. The unit of
/// truth for which parts of a remote MP4 exist locally.
struct ByteRangeSet: Codable, Equatable, Sendable {
    private(set) var runs: [DownloadByteRange] = []

    var totalBytes: Int64 { runs.reduce(0) { $0 + $1.length } }

    mutating func insert(_ range: DownloadByteRange) {
        var merged = range
        var kept: [DownloadByteRange] = []
        for run in runs {
            if run.end + 1 < merged.start || merged.end + 1 < run.start {
                kept.append(run)
            } else {
                merged = DownloadByteRange(
                    start: min(run.start, merged.start),
                    end: max(run.end, merged.end)
                )
            }
        }
        kept.append(merged)
        runs = kept.sorted { $0.start < $1.start }
    }

    func contains(_ range: DownloadByteRange) -> Bool {
        runs.contains { $0.start <= range.start && range.end <= $0.end }
    }

    func missingRanges(in range: DownloadByteRange) -> [DownloadByteRange] {
        var missing: [DownloadByteRange] = []
        var cursor = range.start
        for run in runs where run.end >= range.start && run.start <= range.end {
            if run.start > cursor {
                missing.append(DownloadByteRange(start: cursor, end: run.start - 1))
            }
            cursor = max(cursor, run.end + 1)
            if cursor > range.end { break }
        }
        if cursor <= range.end {
            missing.append(DownloadByteRange(start: cursor, end: range.end))
        }
        return missing
    }

    /// Contiguous cached byte count starting exactly at `start`, capped at `limit`.
    func prefixLength(from start: Int64, limit: Int64) -> Int64 {
        guard let run = runs.first(where: { $0.start <= start && start <= $0.end })
        else { return 0 }
        return min(run.end - start + 1, limit)
    }
}
