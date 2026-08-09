import Testing
import Foundation
@testable import PatataTubeKit

struct SegmentByteSinkTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sink-\(UUID().uuidString).part")
    }

    @Test func appendsFromZeroOnFreshFile() throws {
        let url = tempFile()
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 0)
        try sink.append(Data([1, 2, 3]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func continuesFromExistingPrefix() throws {
        let url = tempFile()
        try Data([1, 2, 3]).write(to: url)
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 3)
        try sink.append(Data([4, 5]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5]))
    }

    @Test func truncatesBytesBeyondExpectedOffset() throws {
        // A pause can land mid-write; anything past the offset the server
        // will re-send must be dropped, or the file corrupts on resume.
        let url = tempFile()
        try Data([1, 2, 3, 9, 9]).write(to: url)
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 3)
        try sink.append(Data([4]))
        sink.close()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
    }

    @Test func refusesWhenFileShorterThanOffset() {
        let url = tempFile()
        try? Data([1]).write(to: url)
        #expect(throws: (any Error).self) {
            _ = try SegmentByteSink(partURL: url, expectedOffset: 5)
        }
    }

    @Test func refusesANonZeroOffsetWhenNoPartFileExists() {
        let url = tempFile()
        #expect(throws: (any Error).self) {
            _ = try SegmentByteSink(partURL: url, expectedOffset: 4)
        }
    }

    @Test func byteCountTracksTheOffsetPlusEverythingAppended() throws {
        let url = tempFile()
        try Data([1, 2]).write(to: url)
        let sink = try SegmentByteSink(partURL: url, expectedOffset: 2)
        #expect(sink.byteCount == 2)
        try sink.append(Data([3, 4, 5]))
        #expect(sink.byteCount == 5)
        sink.close()
    }
}
