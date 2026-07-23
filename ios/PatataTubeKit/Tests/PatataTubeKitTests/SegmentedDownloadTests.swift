import Foundation
import Testing
@testable import PatataTubeKit

private final class FailingPublicationFileManager: FileManager, @unchecked Sendable {
    let blockedSource: URL

    init(blockedSource: URL) {
        self.blockedSource = blockedSource
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL == blockedSource {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@Suite("Segmented download primitives", .serialized)
struct SegmentedDownloadTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("segments-\(UUID().uuidString)")
    }

    @Test func splitsOneThroughFourStreamsWithoutGapsOrOverlap() throws {
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 1) == [
            .init(start: 0, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 2) == [
            .init(start: 0, end: 4),
            .init(start: 5, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 3) == [
            .init(start: 0, end: 2),
            .init(start: 3, end: 5),
            .init(start: 6, end: 9),
        ])
        #expect(try DownloadByteRange.split(totalByteCount: 10, streamCount: 4) == [
            .init(start: 0, end: 1),
            .init(start: 2, end: 4),
            .init(start: 5, end: 6),
            .init(start: 7, end: 9),
        ])
    }

    @Test func tinyFilesUseOnlyNonemptyRanges() throws {
        #expect(try DownloadByteRange.split(totalByteCount: 2, streamCount: 4) == [
            .init(start: 0, end: 0),
            .init(start: 1, end: 1),
        ])
        #expect(throws: SegmentedDownloadError.invalidTotalByteCount) {
            try DownloadByteRange.split(totalByteCount: 0, streamCount: 2)
        }
        #expect(throws: SegmentedDownloadError.invalidStreamCount) {
            try DownloadByteRange.split(totalByteCount: 10, streamCount: 0)
        }
        #expect(throws: SegmentedDownloadError.invalidStreamCount) {
            try DownloadByteRange.split(totalByteCount: 10, streamCount: 5)
        }
    }

    @Test func manifestRoundTripsAndKeepsOriginalCount() throws {
        let store = SegmentedDownloadStore(root: root())
        let manifest = try SegmentedDownloadManifest.make(
            videoId: 17,
            versionId: 3,
            remoteURL: URL(string: "https://srv.test/videos/17/stream?version_id=3")!,
            requestedStreamCount: 4,
            totalByteCount: 11,
            etag: "\"v17\""
        )

        try store.write(manifest)
        let loaded = try store.load(cacheKey: "17:3")

        #expect(loaded == manifest)
        #expect(loaded.requestedStreamCount == 4)
        #expect(loaded.effectiveStreamCount == 4)
        #expect(loaded.segments.map(\.range) == [
            .init(start: 0, end: 1),
            .init(start: 2, end: 4),
            .init(start: 5, end: 7),
            .init(start: 8, end: 10),
        ])
    }

    @Test func validatesProbeAndRejectsAFullResponse() throws {
        let url = URL(string: "https://srv.test/video")!
        let valid = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes 0-0/10",
                "Content-Length": "1",
                "ETag": "\"v1\"",
            ]
        )!
        #expect(try SegmentedDownloadStore.validateProbe(valid, bodyCount: 1)
                == DownloadProbe(totalByteCount: 10, etag: "\"v1\""))

        let full = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "10", "ETag": "\"v1\""]
        )!
        #expect(throws: SegmentedDownloadError.invalidProbe) {
            try SegmentedDownloadStore.validateProbe(full, bodyCount: 10)
        }
    }

    @Test func aggregateProgressCountsCompletedAndPartialBytesOnce() throws {
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 8,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/video")!,
            requestedStreamCount: 2,
            totalByteCount: 10,
            etag: "\"v1\""
        )
        manifest.segments[0].isComplete = true
        manifest.segments[0].persistedByteCount = 5
        manifest.segments[1].persistedByteCount = 2

        #expect(SegmentedDownloadStore.progress(
            manifest: manifest,
            activeByteCounts: [1: 3]
        ) == 0.8)
        #expect(SegmentedDownloadStore.progress(
            manifest: manifest,
            activeByteCounts: [1: 99]
        ) == 1)
    }

    @Test func assemblesCompletedPartsInIndexOrderAndCleansScratch() throws {
        let root = root()
        let store = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 9,
            versionId: 2,
            remoteURL: URL(string: "https://srv.test/video")!,
            requestedStreamCount: 3,
            totalByteCount: 6,
            etag: "\"v1\""
        )
        try store.write(manifest)
        for index in manifest.segments.indices {
            manifest.segments[index].isComplete = true
            let bytes = Data(repeating: UInt8(index + 1), count: 2)
            try bytes.write(to: store.partURL(cacheKey: manifest.cacheKey, index: index))
        }
        try store.write(manifest)

        let destination = root.appendingPathComponent("9.v2.mp4")
        try store.assemble(manifest: manifest, destination: destination)

        #expect(try Data(contentsOf: destination) == Data([1, 1, 2, 2, 3, 3]))
        #expect(!FileManager.default.fileExists(
            atPath: store.directory(cacheKey: manifest.cacheKey).path
        ))
    }

    @Test func retryAfterAssemblyFailureUsesCleanScratchFile() throws {
        let root = root()
        let store = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 10,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/video")!,
            requestedStreamCount: 2,
            totalByteCount: 6,
            etag: "\"v1\""
        )
        manifest.segments.indices.forEach { manifest.segments[$0].isComplete = true }
        try store.write(manifest)
        try Data([1, 1, 1]).write(
            to: store.partURL(cacheKey: manifest.cacheKey, index: 0)
        )

        let assembly = store.assemblyURL(cacheKey: manifest.cacheKey)
        try Data([9, 9, 9, 9, 9, 9]).write(to: assembly)
        let destination = root.appendingPathComponent("10.mp4")

        #expect(throws: SegmentedDownloadError.missingSegment(index: 1)) {
            try store.assemble(manifest: manifest, destination: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: assembly.path))

        try Data([2, 2, 2]).write(
            to: store.partURL(cacheKey: manifest.cacheKey, index: 1)
        )
        try store.assemble(manifest: manifest, destination: destination)

        #expect(try Data(contentsOf: destination) == Data([1, 1, 1, 2, 2, 2]))
    }

    @Test func assemblyFailureBeforeStreamingRemovesStaleScratch() throws {
        let root = root()
        let store = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 11,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/video")!,
            requestedStreamCount: 1,
            totalByteCount: 3,
            etag: "\"v1\""
        )
        try store.write(manifest)
        let assembly = store.assemblyURL(cacheKey: manifest.cacheKey)
        try Data([9, 9, 9]).write(to: assembly)
        manifest.segments[0].persistedByteCount = 4

        #expect(throws: SegmentedDownloadError.corruptManifest) {
            try store.assemble(
                manifest: manifest,
                destination: root.appendingPathComponent("11.mp4")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: assembly.path))
    }

    @Test func publicationFailurePreservesExistingDestination() throws {
        let root = root()
        let setupStore = SegmentedDownloadStore(root: root)
        var manifest = try SegmentedDownloadManifest.make(
            videoId: 12,
            versionId: nil,
            remoteURL: URL(string: "https://srv.test/video")!,
            requestedStreamCount: 1,
            totalByteCount: 3,
            etag: "\"v1\""
        )
        manifest.segments[0].isComplete = true
        try setupStore.write(manifest)
        try Data([2, 2, 2]).write(
            to: setupStore.partURL(cacheKey: manifest.cacheKey, index: 0)
        )
        let destination = root.appendingPathComponent("12.mp4")
        let previous = Data([1, 1, 1])
        try previous.write(to: destination)

        let store = SegmentedDownloadStore(
            root: root,
            fileManager: FailingPublicationFileManager(
                blockedSource: setupStore.assemblyURL(cacheKey: manifest.cacheKey)
            )
        )

        #expect(throws: CocoaError.self) {
            try store.assemble(manifest: manifest, destination: destination)
        }
        #expect(try Data(contentsOf: destination) == previous)
    }
}
