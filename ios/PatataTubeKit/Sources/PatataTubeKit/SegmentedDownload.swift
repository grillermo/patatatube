import Foundation

private func isValidStrongETag(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 2,
          bytes.first == 0x22,
          bytes.last == 0x22
    else { return false }
    return bytes.dropFirst().dropLast().allSatisfy {
        $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80
    }
}

enum SegmentedDownloadError: Error, Equatable {
    case invalidStreamCount
    case invalidTotalByteCount
    case invalidProbe
    case invalidSegmentResponse(index: Int)
    case changedEntity
    case lengthMismatch(expected: Int64, actual: Int64)
    case corruptManifest
    case missingSegment(index: Int)
}

struct DownloadByteRange: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }
    var headerValue: String { "bytes=\(start)-\(end)" }

    static func split(
        totalByteCount: Int64,
        streamCount: Int
    ) throws -> [DownloadByteRange] {
        guard totalByteCount > 0 else {
            throw SegmentedDownloadError.invalidTotalByteCount
        }
        guard (1...4).contains(streamCount) else {
            throw SegmentedDownloadError.invalidStreamCount
        }
        let count = min(Int64(streamCount), totalByteCount)
        let quotient = totalByteCount / count
        let remainder = totalByteCount % count

        func boundary(_ index: Int64) -> Int64 {
            quotient * index + (remainder * index) / count
        }

        return (0..<count).map { index in
            DownloadByteRange(
                start: boundary(index),
                end: boundary(index + 1) - 1
            )
        }
    }
}

struct DownloadSegmentRecord: Codable, Equatable, Sendable {
    let index: Int
    let range: DownloadByteRange
    var isComplete: Bool
    var persistedByteCount: Int64
}

struct SegmentedDownloadManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let allowedStreamCounts = 1...4

    let schemaVersion: Int
    let videoId: Int
    let versionId: Int?
    let remoteURL: URL
    let requestedStreamCount: Int
    let effectiveStreamCount: Int
    let totalByteCount: Int64
    let etag: String
    var segments: [DownloadSegmentRecord]

    var cacheKey: String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    static func make(
        videoId: Int,
        versionId: Int?,
        remoteURL: URL,
        requestedStreamCount: Int,
        totalByteCount: Int64,
        etag: String
    ) throws -> SegmentedDownloadManifest {
        let ranges = try DownloadByteRange.split(
            totalByteCount: totalByteCount,
            streamCount: requestedStreamCount
        )
        return SegmentedDownloadManifest(
            schemaVersion: currentSchemaVersion,
            videoId: videoId,
            versionId: versionId,
            remoteURL: remoteURL,
            requestedStreamCount: requestedStreamCount,
            effectiveStreamCount: ranges.count,
            totalByteCount: totalByteCount,
            etag: etag,
            segments: ranges.enumerated().map {
                DownloadSegmentRecord(
                    index: $0.offset,
                    range: $0.element,
                    isComplete: false,
                    persistedByteCount: 0
                )
            }
        )
    }

    func validated() throws -> SegmentedDownloadManifest {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.allowedStreamCounts.contains(requestedStreamCount),
              effectiveStreamCount == segments.count,
              effectiveStreamCount <= requestedStreamCount,
              totalByteCount > 0,
              isValidStrongETag(etag),
              segments.map(\.index) == Array(segments.indices),
              segments.first?.range.start == 0,
              segments.last?.range.end == totalByteCount - 1,
              segments.allSatisfy({
                  $0.range.start >= 0
                      && $0.range.end >= $0.range.start
                      && $0.persistedByteCount >= 0
                      && $0.persistedByteCount <= $0.range.length
              })
        else { throw SegmentedDownloadError.corruptManifest }

        for pair in zip(segments, segments.dropFirst()) {
            guard pair.0.range.end + 1 == pair.1.range.start else {
                throw SegmentedDownloadError.corruptManifest
            }
        }
        return self
    }
}

struct DownloadProbe: Equatable, Sendable {
    let totalByteCount: Int64
    let etag: String
}

struct SegmentedDownloadStore: @unchecked Sendable {
    let root: URL
    private let fileManager: FileManager
    private let publish: (FileManager, URL, URL) throws -> Void

    init(
        root: URL,
        fileManager: FileManager = .default,
        publish: @escaping (FileManager, URL, URL) throws -> Void = {
            fileManager, destination, assembly in
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: assembly,
                backupItemName: nil,
                options: []
            )
        }
    ) {
        self.root = root
        self.fileManager = fileManager
        self.publish = publish
    }

    private var downloadsRoot: URL {
        root.appendingPathComponent(".downloads", isDirectory: true)
    }

    func directory(cacheKey: String) -> URL {
        downloadsRoot.appendingPathComponent(cacheKey, isDirectory: true)
    }

    func manifestURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("manifest.json")
    }

    func partURL(cacheKey: String, index: Int) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("segment-\(index).part")
    }

    func resumeURL(cacheKey: String, index: Int) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("segment-\(index).resume")
    }

    func assemblyURL(cacheKey: String) -> URL {
        directory(cacheKey: cacheKey).appendingPathComponent("assembled.tmp")
    }

    func write(_ manifest: SegmentedDownloadManifest) throws {
        _ = try manifest.validated()
        let directory = directory(cacheKey: manifest.cacheKey)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(cacheKey: manifest.cacheKey), options: .atomic)
    }

    func load(cacheKey: String) throws -> SegmentedDownloadManifest {
        do {
            let data = try Data(contentsOf: manifestURL(cacheKey: cacheKey))
            let manifest = try JSONDecoder().decode(
                SegmentedDownloadManifest.self,
                from: data
            ).validated()
            guard manifest.cacheKey == cacheKey else {
                throw SegmentedDownloadError.corruptManifest
            }
            return manifest
        } catch let error as SegmentedDownloadError {
            throw error
        } catch {
            throw SegmentedDownloadError.corruptManifest
        }
    }

    func manifests() -> [SegmentedDownloadManifest] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: downloadsRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        return directories.compactMap { directory in
            let key = directory.lastPathComponent
            do {
                return try load(cacheKey: key)
            } catch {
                try? fileManager.removeItem(at: directory)
                return nil
            }
        }
    }

    func remove(cacheKey: String) {
        try? fileManager.removeItem(at: directory(cacheKey: cacheKey))
    }

    static func validateProbe(
        _ response: HTTPURLResponse,
        bodyCount: Int
    ) throws -> DownloadProbe {
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              response.value(forHTTPHeaderField: "Content-Length") == "1",
              bodyCount == 1,
              let etag = response.value(forHTTPHeaderField: "ETag"),
              isValidStrongETag(etag),
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes 0-0/"),
              let total = Int64(contentRange.dropFirst("bytes 0-0/".count)),
              total > 0
        else { throw SegmentedDownloadError.invalidProbe }
        return DownloadProbe(totalByteCount: total, etag: etag)
    }

    static func validateSegment(
        _ response: HTTPURLResponse,
        planned: DownloadSegmentRecord,
        etag: String,
        totalByteCount: Int64,
        fileSize: Int64,
        resumed: Bool
    ) throws {
        guard response.statusCode == 206 else {
            if (400..<600).contains(response.statusCode) {
                throw APIError.badStatus(response.statusCode)
            }
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
        guard response.value(forHTTPHeaderField: "ETag") == etag else {
            throw SegmentedDownloadError.changedEntity
        }
        guard fileSize == planned.range.length else {
            throw SegmentedDownloadError.lengthMismatch(
                expected: planned.range.length,
                actual: fileSize
            )
        }
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = parseContentRange(value),
              parsed.totalByteCount == totalByteCount,
              response.value(forHTTPHeaderField: "Content-Length")
                == "\(parsed.range.length)"
        else {
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
        let validRange = resumed
            ? parsed.range.start >= planned.range.start
                && parsed.range.end == planned.range.end
                && parsed.range.start <= parsed.range.end
            : parsed.range == planned.range
        guard validRange else {
            throw SegmentedDownloadError.invalidSegmentResponse(index: planned.index)
        }
    }

    static func progress(
        manifest: SegmentedDownloadManifest,
        activeByteCounts: [Int: Int64]
    ) -> Double {
        let received = manifest.segments.reduce(Int64(0)) { total, segment in
            let active = activeByteCounts[segment.index] ?? 0
            let bytes = segment.isComplete
                ? segment.range.length
                : min(segment.range.length, max(segment.persistedByteCount, active))
            return total + bytes
        }
        return min(max(Double(received) / Double(manifest.totalByteCount), 0), 1)
    }

    func assemble(
        manifest: SegmentedDownloadManifest,
        destination: URL
    ) throws {
        let assembly = assemblyURL(cacheKey: manifest.cacheKey)
        defer { try? fileManager.removeItem(at: assembly) }

        let validated = try manifest.validated()
        guard validated.segments.allSatisfy(\.isComplete) else {
            throw SegmentedDownloadError.corruptManifest
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: assembly.path) {
            try fileManager.removeItem(at: assembly)
        }
        guard fileManager.createFile(atPath: assembly.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: assembly)
            defer { try? output.close() }

            for segment in validated.segments {
                let part = partURL(cacheKey: validated.cacheKey, index: segment.index)
                guard fileManager.fileExists(atPath: part.path) else {
                    throw SegmentedDownloadError.missingSegment(index: segment.index)
                }
                let attributes = try fileManager.attributesOfItem(atPath: part.path)
                let partSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard partSize == segment.range.length else {
                    throw SegmentedDownloadError.lengthMismatch(
                        expected: segment.range.length,
                        actual: partSize
                    )
                }
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576),
                      !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
        }

        let attributes = try fileManager.attributesOfItem(atPath: assembly.path)
        let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == validated.totalByteCount else {
            throw SegmentedDownloadError.lengthMismatch(
                expected: validated.totalByteCount,
                actual: actual
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            try publish(fileManager, destination, assembly)
        } else {
            try fileManager.moveItem(at: assembly, to: destination)
        }
        remove(cacheKey: validated.cacheKey)
    }

    private struct ParsedContentRange {
        let range: DownloadByteRange
        let totalByteCount: Int64
    }

    private static func parseContentRange(_ value: String) -> ParsedContentRange? {
        guard value.hasPrefix("bytes "),
              let slash = value.firstIndex(of: "/"),
              let total = Int64(value[value.index(after: slash)...])
        else { return nil }
        let interval = value[value.index(value.startIndex, offsetBy: 6)..<slash]
        let parts = interval.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1])
        else { return nil }
        return ParsedContentRange(
            range: DownloadByteRange(start: start, end: end),
            totalByteCount: total
        )
    }
}
