import Foundation

/// Interval algebra over inclusive `DownloadByteRange`s used to track which
/// byte ranges of a video have been captured to disk during playback.
enum CapturedRanges {
    /// Insert `range` into a sorted, non-overlapping set, merging any ranges
    /// that overlap or touch (adjacency: `a.end + 1 == b.start`).
    static func inserting(
        _ range: DownloadByteRange,
        into ranges: [DownloadByteRange]
    ) -> [DownloadByteRange] {
        var merged = ranges.isEmpty ? range : ranges[0]
        var result: [DownloadByteRange] = []
        let all = (ranges + [range]).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
        }
        merged = all[0]
        for next in all.dropFirst() {
            if next.start <= merged.end + 1 {
                merged = DownloadByteRange(start: merged.start, end: max(merged.end, next.end))
            } else {
                result.append(merged)
                merged = next
            }
        }
        result.append(merged)
        return result
    }

    /// The inclusive ranges within `[0, total-1]` not covered by `ranges`.
    static func complement(
        of ranges: [DownloadByteRange],
        over total: Int64
    ) -> [DownloadByteRange] {
        guard total > 0 else { return [] }
        let sorted = ranges.sorted { $0.start < $1.start }
        var gaps: [DownloadByteRange] = []
        var cursor: Int64 = 0
        for range in sorted {
            if range.start > cursor {
                gaps.append(DownloadByteRange(start: cursor, end: range.start - 1))
            }
            cursor = max(cursor, range.end + 1)
        }
        if cursor < total {
            gaps.append(DownloadByteRange(start: cursor, end: total - 1))
        }
        return gaps
    }

    static func coveredBytes(_ ranges: [DownloadByteRange]) -> Int64 {
        ranges.reduce(0) { $0 + $1.length }
    }

    static func isComplete(_ ranges: [DownloadByteRange], total: Int64) -> Bool {
        ranges.count == 1 && ranges[0].start == 0 && ranges[0].end == total - 1
    }
}
