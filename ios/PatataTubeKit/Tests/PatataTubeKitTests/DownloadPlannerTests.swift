import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Download planner and manifest types")
struct DownloadPlannerTests {
    @Test func fourStreamsOverAnEmptyFileSplitLikeTheOldSegments() {
        let starts = DownloadPlanner.starts(
            freeHoles: [DownloadByteRange(start: 0, end: 22)],
            claims: [],
            slots: 4,
            minPiece: 1
        )
        // Claimed in this order these become 0-4, 5-10, 11-16, 17-22 — the
        // exact ranges DownloadByteRange.split produced for 23 bytes.
        #expect(starts == [0, 11, 17, 5])
    }

    @Test func freeHolesComeFirstLargestFirst() {
        let starts = DownloadPlanner.starts(
            freeHoles: [
                DownloadByteRange(start: 0, end: 9),
                DownloadByteRange(start: 50, end: 99),
            ],
            claims: [],
            slots: 2,
            minPiece: 1
        )
        #expect(starts == [50, 0])
    }

    @Test func anIdleClaimCountsAsAFreeHoleFromItsCursor() {
        let starts = DownloadPlanner.starts(
            freeHoles: [],
            claims: [.init(cursor: 300, end: 999, idle: true)],
            slots: 1,
            minPiece: 1_000
        )
        #expect(starts == [300])
    }

    @Test func aBusyClaimIsSplitOnlyWhenItsRemainderIsWorthIt() {
        let busy = DownloadPlanner.Claim(cursor: 0, end: 99, idle: false)
        #expect(DownloadPlanner.starts(freeHoles: [], claims: [busy], slots: 1, minPiece: 50) == [50])
        #expect(DownloadPlanner.starts(freeHoles: [], claims: [busy], slots: 1, minPiece: 51) == [])
    }

    @Test func noSlotsMeansNoStarts() {
        #expect(DownloadPlanner.starts(
            freeHoles: [DownloadByteRange(start: 0, end: 9)], claims: [], slots: 0, minPiece: 1
        ) == [])
    }

    @Test func keysMapToTheLegacyFilenames() {
        #expect(MediaKey.key(videoId: 812, versionId: nil) == "812")
        #expect(MediaKey.key(videoId: 812, versionId: 3) == "812:3")
        #expect(MediaKey.finishedFilename("812") == "812.mp4")
        #expect(MediaKey.finishedFilename("812:3") == "812.v3.mp4")
        #expect(MediaKey.videoId(of: "812:3") == 812)
        #expect(MediaKey.versionId(of: "812:3") == 3)
        #expect(MediaKey.versionId(of: "812") == nil)
    }

    @Test func nextCoveredFindsTheFirstStoredByteAtOrAfter() {
        var set = ByteRangeSet()
        set.insert(DownloadByteRange(start: 10, end: 19))
        set.insert(DownloadByteRange(start: 40, end: 49))
        #expect(set.nextCovered(atOrAfter: 0) == 10)
        #expect(set.nextCovered(atOrAfter: 15) == 15)
        #expect(set.nextCovered(atOrAfter: 20) == 40)
        #expect(set.nextCovered(atOrAfter: 50) == nil)
    }

    @Test func manifestRoundTripsAndReportsCompleteness() throws {
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 99))
        let manifest = MediaEntryManifest(
            key: "5",
            identity: MediaIdentity(etag: "\"e\"", totalByteCount: 100),
            committed: committed,
            pin: PinState(
                job: DownloadJobParameters(
                    remoteURL: URL(string: "https://srv.test/videos/5/stream")!,
                    streamCount: 2, previewURL: nil, showPosterKey: nil, showPosterURL: nil
                ),
                paused: true
            ),
            lastAccess: Date(timeIntervalSince1970: 1_000)
        )
        let decoded = try JSONDecoder().decode(
            MediaEntryManifest.self, from: JSONEncoder().encode(manifest)
        ).validated()
        #expect(decoded == manifest)
        #expect(decoded.isComplete)
        #expect(decoded.progress == 1)
    }

    @Test func aManifestWithBytesButNoIdentityIsCorrupt() {
        var committed = ByteRangeSet()
        committed.insert(DownloadByteRange(start: 0, end: 9))
        let manifest = MediaEntryManifest(
            key: "5", identity: nil, committed: committed, pin: nil, lastAccess: Date()
        )
        #expect(throws: MediaStoreError.corruptManifest) { try manifest.validated() }
    }
}
