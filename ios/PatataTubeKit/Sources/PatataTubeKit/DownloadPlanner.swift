import Foundation

/// Where download fetchers should start next. Pure, so the splitting rule is
/// testable without a store; `MediaStore.claimForDownload` claims the result.
enum DownloadPlanner {
    struct Claim: Equatable, Sendable {
        let cursor: Int64
        let end: Int64
        /// A playback fetcher parked at its read-ahead lead. Its remainder is
        /// free for the taking, or a paused video would stall the download.
        let idle: Bool
    }

    /// Up to `slots` start offsets. Unclaimed holes (and idle claims' remainders)
    /// come first, largest first. Remaining slots split the largest unfetched
    /// remainder at its midpoint, as long as it is at least `2 * minPiece`.
    static func starts(
        freeHoles: [DownloadByteRange],
        claims: [Claim],
        slots: Int,
        minPiece: Int64
    ) -> [Int64] {
        guard slots > 0 else { return [] }
        var starts: [Int64] = []
        var busy: [(cursor: Int64, end: Int64)] = claims
            .filter { !$0.idle }
            .map { ($0.cursor, $0.end) }
        let open = (freeHoles + claims.filter(\.idle).map {
            DownloadByteRange(start: $0.cursor, end: $0.end)
        })
            .filter { $0.length > 0 }
            .sorted { $0.length > $1.length }

        for hole in open where starts.count < slots {
            starts.append(hole.start)
            busy.append((hole.start, hole.end))
        }
        while starts.count < slots {
            guard let index = busy.indices.max(by: {
                busy[$0].end - busy[$0].cursor < busy[$1].end - busy[$1].cursor
            }) else { break }
            let segment = busy[index]
            let remainder = segment.end - segment.cursor + 1
            guard remainder >= 2 * minPiece else { break }
            let mid = segment.cursor + remainder / 2
            busy[index] = (segment.cursor, mid - 1)
            busy.append((mid, segment.end))
            starts.append(mid)
        }
        return starts
    }
}
