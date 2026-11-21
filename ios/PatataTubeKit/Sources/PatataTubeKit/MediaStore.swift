import Foundation

struct ClaimID: Hashable, Sendable {
    let raw: UInt64
}

enum ClaimOwner: String, Sendable {
    case playback
    case download
}

struct ClaimSnapshot: Equatable, Sendable {
    let id: ClaimID
    let owner: ClaimOwner
    /// The next byte this claim's fetcher will commit.
    let cursor: Int64
    let end: Int64
    let idle: Bool
}

enum ClaimResult: Equatable, Sendable {
    case granted(ClaimSnapshot)
    case alreadyCommitted
    /// A fetcher close behind is about to commit this byte: wait for a change
    /// after `version` instead of fetching it twice.
    case covered(ClaimSnapshot, version: UInt64)
    case noEntry
}

enum CommitResult: Equatable, Sendable {
    /// Keep going. The claim now ends at this byte; it may have been shortened.
    case continueThrough(Int64)
    /// The claim is over: it reached its end, or someone took over the rest.
    case finished
    /// That commit completed the file, which is now the finished mp4.
    case promoted
    /// The entry was reset or deleted; these bytes belong to nothing.
    case stale
}

struct Availability: Equatable, Sendable {
    let generation: Int
    /// Committed bytes from the asked offset onward, contiguous.
    let bytes: Int64
}

/// One byte store per video, shared by the stream proxy and downloads.
///
/// An entry is `Documents/videos/.store/<key>/` holding a sparse `data.bin`
/// and `entry.json` (`MediaEntryManifest`). In memory each entry also has
/// **claims**: ranges a fetcher is downloading right now. Claims never overlap,
/// so a byte is fetched once even while a video is watched and downloaded at
/// the same time. Fetchers write `data.bin` through their own handles, then
/// `commit`; only committed bytes are ever served. Whatever commit closes the
/// last hole renames `data.bin` to the finished `videos/<id>.mp4`.
///
/// Every change bumps a per-key version and wakes `waitForChange` callers;
/// that is how a reader waits for a fetcher and a download wakes for a hole.
public actor MediaStore {
    public static let defaultBudgetBytes: Int64 = 50 * 1024 * 1024 * 1024

    struct Tuning: Sendable {
        /// Rewrite `entry.json` at most this often, or after this many new
        /// bytes, whichever comes first: a crash loses a bounded amount.
        var manifestFlushInterval: TimeInterval = 2
        var manifestFlushBytes: Int64 = 1_048_576
    }

    private final class Entry {
        var manifest: MediaEntryManifest
        var generation: Int
        var claims: [ClaimID: Claim] = [:]
        var readers = 0
        var deleteWhenIdle = false
        var promoted = false
        /// The identity was confirmed with the server in this process.
        var verified = false
        var dirtyBytes: Int64 = 0
        var lastFlush: Date

        init(manifest: MediaEntryManifest, generation: Int, lastFlush: Date) {
            self.manifest = manifest
            self.generation = generation
            self.lastFlush = lastFlush
        }
    }

    private struct Claim {
        let id: ClaimID
        let owner: ClaimOwner
        var cursor: Int64
        var end: Int64
        var idle = false

        var snapshot: ClaimSnapshot {
            ClaimSnapshot(id: id, owner: owner, cursor: cursor, end: end, idle: idle)
        }
    }

    nonisolated let videosRoot: URL
    public nonisolated let storeRoot: URL
    private let budgetBytes: Int64
    private let tuning: Tuning
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var versions: [String: UInt64] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var nextClaimID: UInt64 = 0
    private var nextGenerationValue = 0
    private var loadedAll = false

    init(
        videosRoot: URL,
        budgetBytes: Int64 = MediaStore.defaultBudgetBytes,
        tuning: Tuning = Tuning(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.videosRoot = videosRoot
        self.storeRoot = Self.storeRoot(videosRoot: videosRoot)
        self.budgetBytes = budgetBytes
        self.tuning = tuning
        self.now = now
        Self.prepareRoot(storeRoot)
    }

    // MARK: - Paths

    nonisolated static func storeRoot(videosRoot: URL) -> URL {
        videosRoot.appendingPathComponent(".store", isDirectory: true)
    }

    nonisolated func entryDir(key: String) -> URL {
        storeRoot.appendingPathComponent(key, isDirectory: true)
    }

    nonisolated func dataURL(key: String) -> URL {
        entryDir(key: key).appendingPathComponent("data.bin")
    }

    nonisolated func finishedURL(key: String) -> URL {
        videosRoot.appendingPathComponent(MediaKey.finishedFilename(key))
    }

    nonisolated static func manifestURL(storeRoot: URL, key: String) -> URL {
        storeRoot.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("entry.json")
    }

    private nonisolated static func prepareRoot(_ root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root
        try? directory.setResourceValues(values)
    }

    // MARK: - Manifests on disk

    /// Every readable manifest. Synchronous, for `CacheManager`'s launch-time
    /// mirror, which runs before this actor touches the disk.
    nonisolated static func loadManifests(storeRoot: URL) -> [MediaEntryManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: storeRoot, includingPropertiesForKeys: nil
        )) ?? []
        return dirs.compactMap { readManifest(storeRoot: storeRoot, key: $0.lastPathComponent) }
    }

    nonisolated static func readManifest(storeRoot: URL, key: String) -> MediaEntryManifest? {
        guard let data = try? Data(contentsOf: manifestURL(storeRoot: storeRoot, key: key)),
              let manifest = try? JSONDecoder().decode(MediaEntryManifest.self, from: data).validated(),
              manifest.key == key
        else { return nil }
        return manifest
    }

    nonisolated static func writeManifest(_ manifest: MediaEntryManifest, storeRoot: URL) throws {
        let dir = storeRoot.appendingPathComponent(manifest.key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest)
            .write(to: manifestURL(storeRoot: storeRoot, key: manifest.key), options: .atomic)
    }

    // MARK: - Entries

    private func nextGeneration() -> Int {
        nextGenerationValue += 1
        return nextGenerationValue
    }

    /// The in-memory entry, loading it from disk on first use. An unreadable
    /// entry is deleted: its bytes cannot be trusted without its manifest.
    private func entry(_ key: String) -> Entry? {
        if let entry = entries[key] { return entry }
        let dir = entryDir(key: key)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let manifest = Self.readManifest(storeRoot: storeRoot, key: key),
              manifest.identity == nil
                || FileManager.default.fileExists(atPath: dataURL(key: key).path)
        else {
            DevLog.event(.cache, "store entry unreadable, removed", ["key": key])
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        let entry = Entry(manifest: manifest, generation: nextGeneration(), lastFlush: now())
        entries[key] = entry
        return entry
    }

    private func loadAll() {
        guard !loadedAll else { return }
        loadedAll = true
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: storeRoot, includingPropertiesForKeys: nil
        )) ?? []
        for dir in dirs { _ = entry(dir.lastPathComponent) }
    }

    func manifest(key: String) -> MediaEntryManifest? {
        guard let entry = entry(key), !entry.promoted else { return nil }
        return entry.manifest
    }

    func version(key: String) -> UInt64 {
        versions[key] ?? 0
    }

    /// The identity and generation already confirmed with the server in this
    /// process, if any. A new process always probes once.
    func verifiedIdentity(key: String) -> (identity: MediaIdentity, generation: Int)? {
        guard let entry = entry(key), entry.verified, !entry.promoted,
              let identity = entry.manifest.identity
        else { return nil }
        return (identity, entry.generation)
    }

    /// Forgets that the identity was confirmed, so the next user probes again.
    func invalidate(key: String) {
        entry(key)?.verified = false
    }

    /// Makes `key` an entry for `identity` and returns the generation every
    /// fetcher and reader must carry. Creates the entry, adopts an
    /// identity-less one, or resets one that holds a different identity.
    @discardableResult
    func open(key: String, identity: MediaIdentity) throws -> Int {
        if entries[key] == nil, finishedFileMatches(key: key, identity: identity) {
            // Finished while nobody held an entry: answer for the mp4.
            var committed = ByteRangeSet()
            committed.insert(DownloadByteRange(start: 0, end: identity.totalByteCount - 1))
            let entry = Entry(
                manifest: MediaEntryManifest(
                    key: key, identity: identity, committed: committed, pin: nil, lastAccess: now()
                ),
                generation: nextGeneration(),
                lastFlush: now()
            )
            entry.promoted = true
            entry.verified = true
            entries[key] = entry
            return entry.generation
        }
        let entry = try self.entry(key) ?? create(key: key, identity: identity)
        if entry.manifest.identity == nil {
            try createDataFile(key: key)
            entry.manifest.identity = identity
            try flush(key, entry)
        } else if entry.manifest.identity != identity, !entry.promoted {
            try reset(key, entry, to: identity)
        }
        try completePromotionIfNeeded(key, entry)
        entry.verified = true
        return entry.generation
    }

    /// True when a finished mp4 exists for `key` and has the identity's size.
    /// One of another size is stale: it is deleted, so the store never
    /// advertises bytes that are not there.
    private func finishedFileMatches(key: String, identity: MediaIdentity) -> Bool {
        let url = finishedURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        if size == identity.totalByteCount { return true }
        DevLog.event(.cache, "finished mp4 size mismatch, removed", [
            "key": key, "size": size.map { "\($0)" } ?? "-", "expected": "\(identity.totalByteCount)",
        ])
        try? FileManager.default.removeItem(at: url)
        return false
    }

    /// A promotion that failed leaves a complete manifest with the file still
    /// in `data.bin`. Any later open or claim tries the rename again.
    private func completePromotionIfNeeded(_ key: String, _ entry: Entry) throws {
        guard !entry.promoted, entry.manifest.isComplete else { return }
        entry.claims.removeAll()
        defer { bump(key) }
        try promote(key, entry)
    }

    private func create(key: String, identity: MediaIdentity?) throws -> Entry {
        let manifest = MediaEntryManifest(
            key: key, identity: identity, committed: ByteRangeSet(), pin: nil, lastAccess: now()
        )
        do {
            try Self.writeManifest(manifest, storeRoot: storeRoot)
            if identity != nil { try createDataFile(key: key) }
        } catch {
            try? FileManager.default.removeItem(at: entryDir(key: key))
            throw MediaStoreError.storageFull
        }
        let entry = Entry(manifest: manifest, generation: nextGeneration(), lastFlush: now())
        entries[key] = entry
        return entry
    }

    private func createDataFile(key: String) throws {
        let url = dataURL(key: key)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw MediaStoreError.storageFull
        }
    }

    /// The server now has a different file under this key. Everything stored
    /// is wrong: open readers see a new generation and end, fetchers' commits
    /// turn stale.
    private func reset(_ key: String, _ entry: Entry, to identity: MediaIdentity) throws {
        DevLog.event(.cache, "store entry reset: identity changed", [
            "key": key,
            "old_etag": entry.manifest.identity?.etag ?? "-",
            "new_etag": identity.etag,
            "old_total": entry.manifest.identity.map { "\($0.totalByteCount)" } ?? "-",
            "new_total": "\(identity.totalByteCount)",
        ])
        entry.generation = nextGeneration()
        entry.claims.removeAll()
        entry.manifest.committed = ByteRangeSet()
        entry.manifest.identity = identity
        entry.dirtyBytes = 0
        try createDataFile(key: key)
        try flush(key, entry)
        bump(key)
    }

    // MARK: - Claims

    /// Asks to fetch from `start` toward `end`. The grant stops before the
    /// next committed or claimed byte. A claim already covering `start` wins
    /// when its fetcher is at most `waitWithin` behind and not idle;
    /// otherwise it is shortened to end just before `start`.
    func claim(
        key: String,
        from start: Int64,
        through end: Int64,
        owner: ClaimOwner,
        waitWithin: Int64
    ) -> ClaimResult {
        guard let entry = entry(key) else { return .noEntry }
        if entry.promoted { return .alreadyCommitted }
        if entry.manifest.isComplete {
            try? completePromotionIfNeeded(key, entry)
            return .alreadyCommitted
        }
        guard let total = entry.manifest.identity?.totalByteCount,
              start >= 0, start < total, end >= start
        else { return .noEntry }
        if entry.manifest.committed.contains(DownloadByteRange(start: start, end: start)) {
            return .alreadyCommitted
        }
        if let holder = entry.claims.values.first(where: { $0.cursor <= start && start <= $0.end }) {
            if !holder.idle, start - holder.cursor <= waitWithin {
                return .covered(holder.snapshot, version: version(key: key))
            }
            shorten(entry, holder.id, toEndBefore: start)
        }
        var granted = min(end, total - 1)
        if let next = entry.manifest.committed.nextCovered(atOrAfter: start) {
            granted = min(granted, next - 1)
        }
        if let next = entry.claims.values.map(\.cursor).filter({ $0 > start }).min() {
            granted = min(granted, next - 1)
        }
        nextClaimID += 1
        let claim = Claim(id: ClaimID(raw: nextClaimID), owner: owner, cursor: start, end: granted)
        entry.claims[claim.id] = claim
        bump(key)
        return .granted(claim.snapshot)
    }

    private func shorten(_ entry: Entry, _ id: ClaimID, toEndBefore start: Int64) {
        guard var claim = entry.claims[id] else { return }
        claim.end = start - 1
        entry.claims[id] = claim.end < claim.cursor ? nil : claim
    }

    func claimSnapshot(key: String, id: ClaimID) -> ClaimSnapshot? {
        entries[key]?.claims[id]?.snapshot
    }

    func claims(key: String) -> [ClaimSnapshot] {
        (entries[key]?.claims.values.map(\.snapshot) ?? []).sorted { $0.cursor < $1.cursor }
    }

    func releaseClaim(key: String, id: ClaimID) {
        guard entries[key]?.claims.removeValue(forKey: id) != nil else { return }
        bump(key)
    }

    /// Marks a playback claim parked at its read-ahead lead (or awake again).
    /// A download may take over an idle claim's remainder.
    func setClaimIdle(key: String, id: ClaimID, idle: Bool) {
        guard let entry = entries[key], var claim = entry.claims[id], claim.idle != idle else { return }
        claim.idle = idle
        entry.claims[id] = claim
        bump(key)
    }

    /// Claims where up to `slots` more download fetchers should run, per
    /// `DownloadPlanner`. Atomic, so two planners can never pick the same byte.
    func claimForDownload(key: String, slots: Int, minPiece: Int64) -> [ClaimSnapshot] {
        guard slots > 0, let entry = entry(key), !entry.promoted,
              let total = entry.manifest.identity?.totalByteCount
        else { return [] }
        var covered = entry.manifest.committed
        for claim in entry.claims.values {
            covered.insert(DownloadByteRange(start: claim.cursor, end: claim.end))
        }
        let starts = DownloadPlanner.starts(
            freeHoles: covered.missingRanges(in: DownloadByteRange(start: 0, end: total - 1)),
            claims: entry.claims.values.map { .init(cursor: $0.cursor, end: $0.end, idle: $0.idle) },
            slots: slots,
            minPiece: minPiece
        )
        var granted: [ClaimID] = []
        for start in starts {
            if case .granted(let snapshot) = claim(
                key: key, from: start, through: total - 1, owner: .download, waitWithin: 0
            ) {
                granted.append(snapshot.id)
            }
        }
        // Re-read: each later claim shortened the one it landed in.
        return granted.compactMap { claimSnapshot(key: key, id: $0) }
    }

    // MARK: - Commits

    /// Records that the claim's bytes from its cursor through `lastByte` are
    /// in `data.bin`. The caller wrote them first.
    func commit(
        key: String,
        claim id: ClaimID,
        generation: Int,
        through lastByte: Int64
    ) throws -> CommitResult {
        guard let entry = entries[key] else {
            return FileManager.default.fileExists(atPath: finishedURL(key: key).path)
                ? .finished : .stale
        }
        if entry.promoted { return .finished }
        guard entry.generation == generation else { return .stale }
        guard var claim = entry.claims[id] else { return .finished }
        guard lastByte >= claim.cursor else {
            throw MediaStoreError.commitOutsideClaim
        }
        // Another claimer may have shortened this claim mid-read; the bytes
        // past its end now belong to that claimer.
        let lastByte = min(lastByte, claim.end)
        let range = DownloadByteRange(start: claim.cursor, end: lastByte)
        entry.manifest.committed.insert(range)
        entry.dirtyBytes += range.length
        entry.manifest.lastAccess = now()
        claim.cursor = lastByte + 1
        // Whatever happens below, the state changed: waiters must wake.
        defer { bump(key) }
        if entry.manifest.isComplete {
            entry.claims.removeAll()
            try promote(key, entry)
            return .promoted
        }
        let done = claim.cursor > claim.end
        entry.claims[id] = done ? nil : claim
        try flushIfDue(key, entry)
        return done ? .finished : .continueThrough(claim.end)
    }

    func available(key: String, from offset: Int64) -> Availability? {
        guard let entry = entry(key), let total = entry.manifest.identity?.totalByteCount else {
            return nil
        }
        if entry.promoted {
            return Availability(generation: entry.generation, bytes: max(total - offset, 0))
        }
        return Availability(
            generation: entry.generation,
            bytes: entry.manifest.committed.prefixLength(from: offset, limit: total)
        )
    }

    // MARK: - Durability and promotion

    private func flushIfDue(_ key: String, _ entry: Entry) throws {
        let due = entry.dirtyBytes >= tuning.manifestFlushBytes
            || now().timeIntervalSince(entry.lastFlush) >= tuning.manifestFlushInterval
        if due { try flush(key, entry) }
    }

    /// Data first, manifest second: a crash can lose bytes the manifest never
    /// recorded, but the manifest never names bytes that are not on disk.
    private func flush(_ key: String, _ entry: Entry) throws {
        do {
            if entry.manifest.identity != nil, entry.dirtyBytes > 0 {
                let handle = try FileHandle(forWritingTo: dataURL(key: key))
                defer { try? handle.close() }
                try handle.synchronize()
            }
            try Self.writeManifest(entry.manifest, storeRoot: storeRoot)
        } catch {
            throw MediaStoreError.storageFull
        }
        entry.dirtyBytes = 0
        entry.lastFlush = now()
    }

    /// Renames the complete `data.bin` to the finished mp4. Open read handles
    /// keep working (the inode survives the rename); new requests are served
    /// from the mp4.
    private func promote(_ key: String, _ entry: Entry) throws {
        let source = dataURL(key: key)
        let destination = finishedURL(key: key)
        do {
            let handle = try FileHandle(forWritingTo: source)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            DevLog.event(.cache, "store promotion failed", ["key": key, "err": "\(error)"])
            throw MediaStoreError.promotionFailed
        }
        try? FileManager.default.removeItem(at: entryDir(key: key))
        entry.promoted = true
        DevLog.event(.cache, "store entry promoted", [
            "key": key,
            "bytes": entry.manifest.identity.map { "\($0.totalByteCount)" } ?? "-",
            "pinned": "\(entry.manifest.pin != nil)",
        ])
        if entry.readers == 0 { entries[key] = nil }
    }

    // MARK: - Change notification

    /// Returns once `key` changed after `seen` (a commit, a claim taken or
    /// released, a reset, a deletion), or the task is cancelled.
    func waitForChange(key: String, after seen: UInt64) async {
        guard version(key: key) == seen else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[key, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: id) }
        }
    }

    private func cancelWaiter(key: String, id: UUID) {
        waiters[key]?.removeValue(forKey: id)?.resume()
    }

    private func bump(_ key: String) {
        versions[key, default: 0] &+= 1
        guard let woken = waiters.removeValue(forKey: key) else { return }
        for continuation in woken.values { continuation.resume() }
    }
}
