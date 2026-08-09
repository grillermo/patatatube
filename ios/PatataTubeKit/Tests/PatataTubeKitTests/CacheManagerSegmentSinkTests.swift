import Foundation
import Testing
@testable import PatataTubeKit

/// Two silent-corruption guards on the segmented data-task path: replacing a
/// part file's sink must tear the old one down, and a pause teardown that
/// timed out must not let the next transfer continue from bytes another sink
/// may still be draining into.
@Suite("Segment sink replacement and teardown-timeout fail-safe", .serialized)
struct CacheManagerSegmentSinkTests {
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-sinks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func manager(root: URL) -> CacheManager {
        CacheManager(
            root: root,
            configuration: .ephemeral,
            fileManager: .default
        )
    }

    private func context(
        cacheKey: String = "55",
        durablePrefixByteCount: Int64 = 0
    ) -> SegmentTaskContext {
        SegmentTaskContext(
            attemptID: UUID(),
            cacheKey: cacheKey,
            segmentIndex: 0,
            durablePrefixByteCount: durablePrefixByteCount
        )
    }

    /// URLSession can deliver `didReceive response:` twice on one data task.
    /// The second delivery used to blind-assign over the first sink, leaving
    /// its `FileHandle` open on the same part file with its own offset.
    @Test func replacingASegmentSinkHandsBackTheOldOneToBeClosed() throws {
        let root = temporaryRoot()
        let manager = manager(root: root)
        let part = root.appendingPathComponent("0.part")
        #expect(FileManager.default.createFile(atPath: part.path, contents: nil))
        let first = try SegmentByteSink(partURL: part, expectedOffset: 0)
        try first.append(Data([1, 2, 3, 4]))
        manager.segmentSinks[7] = first

        let stale = manager.takeExistingSegmentSink(
            context: context(),
            taskIdentifier: 7
        )

        #expect(stale === first)
        #expect(manager.segmentSinks[7] == nil, "the old sink is unregistered")
        #expect(first.isOpen, "closing is the caller's job, off the lock")
        stale?.close()
        #expect(first.isOpen == false)
    }

    /// After the old sink is closed, the replacement truncates to its own
    /// prefix and the part file holds only the second response's bytes — no
    /// interleaving, and no double-counting of the discarded ones.
    @Test func theReplacementSinkOwnsThePartFileAlone() throws {
        let root = temporaryRoot()
        let manager = manager(root: root)
        let part = root.appendingPathComponent("0.part")
        #expect(FileManager.default.createFile(atPath: part.path, contents: nil))
        let first = try SegmentByteSink(partURL: part, expectedOffset: 0)
        try first.append(Data([1, 2, 3, 4]))
        manager.segmentSinks[7] = first

        manager.takeExistingSegmentSink(context: context(), taskIdentifier: 7)?
            .close()
        let second = try SegmentByteSink(partURL: part, expectedOffset: 0)
        try second.append(Data([9, 9]))
        second.close()

        #expect(try Data(contentsOf: part) == Data([9, 9]))
        #expect(second.byteCount == 2, "the discarded bytes are not counted")
    }

    @Test func takingASinkTwiceYieldsNothingTheSecondTime() throws {
        let root = temporaryRoot()
        let manager = manager(root: root)
        let part = root.appendingPathComponent("0.part")
        #expect(FileManager.default.createFile(atPath: part.path, contents: nil))
        manager.segmentSinks[7] = try SegmentByteSink(
            partURL: part,
            expectedOffset: 0
        )

        manager.takeExistingSegmentSink(context: context(), taskIdentifier: 7)?
            .close()

        #expect(
            manager.takeExistingSegmentSink(
                context: context(),
                taskIdentifier: 7
            ) == nil
        )
    }

    // MARK: - Pause-teardown timeout

    @Test func aSegmentNormallyContinuesFromItsPartFile() {
        #expect(CacheManager.segmentStartPrefix(
            partByteCount: 100,
            segmentLength: 500,
            teardownTimedOut: false
        ) == 100)
    }

    @Test func anAbsentOrFullPartFileStartsFromZero() {
        #expect(CacheManager.segmentStartPrefix(
            partByteCount: nil,
            segmentLength: 500,
            teardownTimedOut: false
        ) == 0)
        #expect(CacheManager.segmentStartPrefix(
            partByteCount: 0,
            segmentLength: 500,
            teardownTimedOut: false
        ) == 0)
        #expect(CacheManager.segmentStartPrefix(
            partByteCount: 500,
            segmentLength: 500,
            teardownTimedOut: false
        ) == 0)
    }

    /// The fail-safe: after a timed-out teardown the previous transfer's sinks
    /// may still be open on these part files, so their contents are not a
    /// trustworthy prefix however plausible their size looks.
    @Test func aTimedOutTeardownRestartsTheSegmentFromZero() {
        #expect(CacheManager.segmentStartPrefix(
            partByteCount: 100,
            segmentLength: 500,
            teardownTimedOut: true
        ) == 0)
    }

    /// The wait gives up after `pauseTeardownTimeout` and records the key —
    /// once, for the transfer that immediately follows it.
    @Test func aTimedOutWaitFlagsTheKeyExactlyOnce() async {
        let root = temporaryRoot()
        let manager = manager(root: root)
        manager.pauseTeardownTimeout = .milliseconds(60)
        manager.pauseTeardownKeys.insert("55")

        await manager.awaitPauseTeardown(for: "55")

        #expect(manager.consumePauseTeardownTimeout(for: "55"))
        #expect(manager.consumePauseTeardownTimeout(for: "55") == false)
    }

    @Test func aTeardownThatWasNeverInProgressFlagsNothing() async {
        let root = temporaryRoot()
        let manager = manager(root: root)
        manager.pauseTeardownTimeout = .milliseconds(60)

        await manager.awaitPauseTeardown(for: "55")

        #expect(manager.consumePauseTeardownTimeout(for: "55") == false)
    }
}
