import Foundation

enum RangeFetchError: Error, Equatable {
    /// The server now has a different file. Carries the new identity when the
    /// response named one (a 200 to an `If-Range` request names none).
    case entityChanged(MediaIdentity?)
    case invalidResponse
    /// The body ended before the requested range did.
    case shortBody
}

enum FetchOutcome: Equatable, Sendable {
    case finished
    case promoted
    case stale
}

struct ContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64

    init?(_ value: String) {
        guard value.hasPrefix("bytes "),
              let slash = value.firstIndex(of: "/"),
              let total = Int64(value[value.index(after: slash)...]),
              total > 0
        else { return nil }
        let bounds = value[value.index(value.startIndex, offsetBy: 6)..<slash]
            .split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total
        else { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}

/// Fetches one claim from upstream into the store: one `Range` request from
/// the claim's cursor to its end, writing each piece to `data.bin` and
/// committing it every `commitSize` bytes. The claim may be shortened while
/// it runs (a reader or a download took over the rest); the fetcher learns
/// that from each commit and stops. A transient failure retries from the
/// last commit, up to `maxAttempts` attempts in all. **The caller releases
/// the claim** when `run` returns.
///
/// A write past a shortened end can happen for at most one commit. It is
/// byte-identical (same identity) and never committed, so it is harmless.
struct RangeFetcher: Sendable {
    static let defaultCommitSize = 256 * 1024

    let store: MediaStore
    let key: String
    let identity: MediaIdentity
    let generation: Int
    let session: URLSession
    let upstream: UpstreamRequests
    var commitSize = RangeFetcher.defaultCommitSize
    var maxAttempts = 4
    var limiter: ReadAheadLimiter?

    func run(claim id: ClaimID) async throws -> FetchOutcome {
        var failures = 0
        while true {
            try Task.checkCancellation()
            guard let claim = await store.claimSnapshot(key: key, id: id) else { return .finished }
            do {
                return try await fetch(claim)
            } catch let error where Self.isTransient(error) && failures + 1 < maxAttempts {
                failures += 1
                DevLog.event(.cache, "range fetch retry", [
                    "key": key, "attempt": "\(failures + 1)", "err": "\(error)",
                ])
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case .badStatus(let status)? = error as? APIError { return (500..<600).contains(status) }
        return error as? RangeFetchError == .shortBody
    }

    static func validate(_ response: HTTPURLResponse, identity: MediaIdentity?, start: Int64) throws {
        switch response.statusCode {
        case 206:
            break
        case 200:
            // An If-Range miss: the server sent the whole, different file.
            throw RangeFetchError.entityChanged(nil)
        case 400..<600:
            throw APIError.badStatus(response.statusCode)
        default:
            throw RangeFetchError.invalidResponse
        }
        guard let range = response.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init) else {
            throw RangeFetchError.invalidResponse
        }
        let etag = response.value(forHTTPHeaderField: "ETag")
        if let identity, etag != identity.etag || range.total != identity.totalByteCount {
            throw RangeFetchError.entityChanged(etag.map { MediaIdentity(etag: $0, totalByteCount: range.total) })
        }
        guard range.start == start else { throw RangeFetchError.invalidResponse }
    }

    private func fetch(_ claim: ClaimSnapshot) async throws -> FetchOutcome {
        var offset = claim.cursor
        var end = claim.end
        guard offset <= end else { return .finished }
        var request = upstream.ranged(DownloadByteRange(start: offset, end: end))
        request.setValue(identity.etag, forHTTPHeaderField: "If-Range")
        let (response, body) = try await DataTaskStream.start(request, session: session)
        defer { body.cancel() }
        try Self.validate(response, identity: identity, start: offset)
        guard let handle = try? FileHandle(forWritingTo: store.dataURL(key: key)) else { return .stale }
        defer { try? handle.close() }

        var pending = Data()
        for try await chunk in body {
            pending.append(chunk)
            guard pending.count >= commitSize else { continue }
            if let outcome = try await commit(&pending, claim: claim.id, offset: &offset, end: &end, handle: handle) {
                return outcome
            }
        }
        if !pending.isEmpty,
           let outcome = try await commit(&pending, claim: claim.id, offset: &offset, end: &end, handle: handle) {
            return outcome
        }
        guard offset > end else { throw RangeFetchError.shortBody }
        return .finished
    }

    /// Writes and commits everything pending, clipped to the claim's end.
    /// Returns an outcome when this fetch is over.
    private func commit(
        _ pending: inout Data,
        claim id: ClaimID,
        offset: inout Int64,
        end: inout Int64,
        handle: FileHandle
    ) async throws -> FetchOutcome? {
        let length = Int(min(Int64(pending.count), end - offset + 1))
        let piece = pending.prefix(length)
        pending = Data()
        try await write(piece, at: offset, handle: handle)
        let result = try await store.commit(
            key: key, claim: id, generation: generation, through: offset + Int64(length) - 1
        )
        offset += Int64(length)
        switch result {
        case .continueThrough(let newEnd):
            end = newEnd
            if offset > end { return .finished }
        case .finished:
            return .finished
        case .promoted:
            return .promoted
        case .stale:
            return .stale
        }
        if let limiter, limiter.wouldWait(nextByte: offset) {
            await store.setClaimIdle(key: key, id: id, idle: true)
            do {
                try await limiter.waitForRoom(nextByte: offset)
            } catch {
                await store.setClaimIdle(key: key, id: id, idle: false)
                throw error
            }
            await store.setClaimIdle(key: key, id: id, idle: false)
        }
        return nil
    }

    /// A failed write evicts one idle unpinned entry and retries once.
    private func write(_ piece: Data, at offset: Int64, handle: FileHandle) async throws {
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: piece)
        } catch {
            DevLog.event(.cache, "store write failed, evicting and retrying", [
                "key": key, "offset": "\(offset)", "bytes": "\(piece.count)", "err": "\(error)",
            ])
            guard await store.evictForStorageFailure(excluding: key) else {
                throw MediaStoreError.storageFull
            }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: piece)
            } catch {
                throw MediaStoreError.storageFull
            }
        }
    }
}
