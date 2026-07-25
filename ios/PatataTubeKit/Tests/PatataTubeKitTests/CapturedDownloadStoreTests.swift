import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Captured download store", .serialized)
struct CapturedDownloadStoreTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)")
    }

    @Test func manifestRoundTrips() throws {
        let store = CapturedDownloadStore(root: root())
        var m = CapturedDownloadManifest.make(
            videoId: 3, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/3/stream")!,
            totalByteCount: 10, etag: "\"v3\"")
        m.capture(.init(start: 0, end: 4))
        try store.write(m)
        #expect(try store.load(cacheKey: "3") == m)
        #expect(store.manifests().map(\.cacheKey) == ["3"])
        store.remove(cacheKey: "3")
        #expect(store.manifests().isEmpty)
    }

    @Test func sparseFileWriteReadRoundTrip() throws {
        let store = CapturedDownloadStore(root: root())
        try store.ensureSparseFile(cacheKey: "9", totalByteCount: 8)
        try store.writeRange(cacheKey: "9", offset: 2, data: Data([0xAA, 0xBB]))
        let read = try store.readRange(cacheKey: "9", range: .init(start: 2, end: 3))
        #expect(read == Data([0xAA, 0xBB]))
    }

    @Test func publishMovesCompletedFileAndRemovesManifest() throws {
        let base = root()
        let store = CapturedDownloadStore(root: base)
        var m = CapturedDownloadManifest.make(
            videoId: 5, versionId: nil,
            remoteURL: URL(string: "https://srv.test/videos/5/stream")!,
            totalByteCount: 4, etag: "\"v5\"")
        m.capture(.init(start: 0, end: 3))
        try store.write(m)
        try store.ensureSparseFile(cacheKey: "5", totalByteCount: 4)
        try store.writeRange(cacheKey: "5", offset: 0, data: Data([1, 2, 3, 4]))
        let dest = base.appendingPathComponent("5.mp4")
        try store.publish(cacheKey: "5", to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3, 4]))
        #expect(store.manifests().isEmpty)
    }
}
