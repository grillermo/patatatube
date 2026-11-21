import FlyingSocks
import Foundation

enum ProxyReadError: Error, Equatable {
    case entryGone
    case entityChanged
}

/// What FlyingFox iterates to send one proxied mp4 body. `HTTPBodySequence`
/// pulls it through `nextBuffer(suggested:)`.
struct ProxyBody: AsyncBufferedSequence {
    typealias Element = UInt8

    let reader: ProxyReadSession

    func makeAsyncIterator() -> Iterator {
        Iterator(reader: reader)
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Buffer = Data

        let reader: ProxyReadSession
        private var spare = Data()

        init(reader: ProxyReadSession) {
            self.reader = reader
        }

        mutating func next() async throws -> UInt8? {
            if spare.isEmpty {
                guard let data = try await reader.nextBuffer(maxCount: 64 * 1024) else { return nil }
                spare = data
            }
            return spare.popFirst()
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            if !spare.isEmpty {
                defer { spare = Data() }
                return spare
            }
            return try await reader.nextBuffer(maxCount: count)
        }
    }
}

/// One proxied response's reader. It serves `window` in order: committed
/// bytes from disk; bytes a fetcher close behind is about to commit, by
/// waiting; otherwise bytes from its own playback fetcher at the playhead,
/// parked `readAhead` ahead of what was sent. Released when FlyingFox drops
/// the body (finished or client hung up). It then cancels only the fetcher
/// it started and ends its read on the entry.
///
/// Only FlyingFox's single body iteration calls `nextBuffer`. The lock
/// covers what the fetcher task writes back and what `deinit` reads.
final class ProxyReadSession: @unchecked Sendable {
    private let store: MediaStore?
    private let key: String
    private let identity: MediaIdentity
    private let generation: Int
    private let window: DownloadByteRange
    private let upstream: UpstreamRequests
    private let session: URLSession
    private let tuning: StreamProxy.Tuning

    private var position: Int64
    private var handle: FileHandle?
    private var passthrough: DataTaskStream?
    private var passthroughOnly: Bool

    private let lock = NSLock()
    private var fetcherTask: Task<Void, Never>?
    private var limiter: ReadAheadLimiter?
    private var fetcherResult: Result<FetchOutcome, Error>?

    /// The caller has already called `store.beginRead(key:)`.
    init(store: MediaStore, key: String, identity: MediaIdentity, generation: Int,
         window: DownloadByteRange, upstream: UpstreamRequests, session: URLSession,
         tuning: StreamProxy.Tuning) {
        self.store = store
        self.key = key
        self.identity = identity
        self.generation = generation
        self.window = window
        self.upstream = upstream
        self.session = session
        self.tuning = tuning
        self.position = window.start
        self.passthroughOnly = false
    }

    /// No room in the store even after evicting: stream without keeping.
    init(passthroughOf window: DownloadByteRange, key: String, identity: MediaIdentity,
         upstream: UpstreamRequests, session: URLSession, tuning: StreamProxy.Tuning) {
        self.store = nil
        self.key = key
        self.identity = identity
        self.generation = -1
        self.window = window
        self.upstream = upstream
        self.session = session
        self.tuning = tuning
        self.position = window.start
        self.passthroughOnly = true
    }

    deinit {
        let (task, limiter) = lock.withLock { (fetcherTask, self.limiter) }
        task?.cancel()
        limiter?.cancel()
        passthrough?.cancel()
        try? handle?.close()
        if let store {
            let key = key
            Task { await store.endRead(key: key) }
        }
    }

    func nextBuffer(maxCount: Int) async throws -> Data? {
        while position <= window.end {
            try Task.checkCancellation()
            guard let store, !passthroughOnly else {
                return try await nextPassthrough()
            }
            guard let availability = await store.available(key: key, from: position) else {
                throw ProxyReadError.entryGone
            }
            guard availability.generation == generation else { throw ProxyReadError.entityChanged }
            if availability.bytes > 0 {
                let count = min(Int64(min(maxCount, tuning.readSize)), availability.bytes, window.end - position + 1)
                return try await read(count, store: store)
            }
            if try await handleFetcherResult(store: store) { continue }
            switch await store.claim(
                key: key, from: position, through: window.end, owner: .playback, waitWithin: tuning.waitWithin
            ) {
            case .alreadyCommitted:
                continue
            case .noEntry:
                throw ProxyReadError.entryGone
            case .covered(_, let version):
                await store.waitForChange(key: key, after: version)
            case .granted(let claim):
                startFetcher(claim, store: store)
            }
        }
        return nil
    }

    private func read(_ count: Int64, store: MediaStore) async throws -> Data {
        if handle == nil { handle = await store.openReadHandle(key: key) }
        guard let handle else { throw ProxyReadError.entryGone }
        try handle.seek(toOffset: UInt64(position))
        guard let data = try handle.read(upToCount: Int(count)), !data.isEmpty else {
            throw ProxyReadError.entryGone
        }
        position += Int64(data.count)
        lock.withLock { limiter }?.advance(to: position)
        return data
    }

    /// Consumes the own fetcher's result, if it has ended. True means loop
    /// again at once.
    private func handleFetcherResult(store: MediaStore) async throws -> Bool {
        let result = lock.withLock { () -> Result<FetchOutcome, Error>? in
            guard let result = fetcherResult else { return nil }
            fetcherResult = nil
            fetcherTask = nil
            limiter = nil
            return result
        }
        guard let result else { return false }
        switch result {
        case .success:
            return true
        case .failure(let error):
            if error as? MediaStoreError == .storageFull {
                DevLog.event(.proxy, "store full, passing through", ["key": key])
                passthroughOnly = true
                return true
            }
            if case .entityChanged(let changed)? = error as? RangeFetchError, let changed {
                // Reset now, so the next request starts on the new file.
                _ = try? await store.open(key: key, identity: changed)
            }
            throw error
        }
    }

    private func startFetcher(_ claim: ClaimSnapshot, store: MediaStore) {
        let limiter = ReadAheadLimiter(lead: tuning.readAhead, position: position)
        let fetcher = RangeFetcher(
            store: store, key: key, identity: identity, generation: generation,
            session: session, upstream: upstream,
            commitSize: tuning.commitSize, maxAttempts: tuning.maxAttempts, limiter: limiter
        )
        let key = key
        let task = Task { [weak self] in
            let result: Result<FetchOutcome, Error>
            do {
                result = .success(try await fetcher.run(claim: claim.id))
            } catch {
                result = .failure(error)
            }
            // Record before releasing: the release wakes the reader, which
            // must see why its fetcher stopped.
            if let self { self.lock.withLock { self.fetcherResult = result } }
            await store.releaseClaim(key: key, id: claim.id)
        }
        lock.withLock {
            fetcherTask = task
            self.limiter = limiter
        }
    }

    private func nextPassthrough() async throws -> Data? {
        if passthrough == nil {
            var request = upstream.ranged(DownloadByteRange(start: position, end: window.end))
            request.setValue(identity.etag, forHTTPHeaderField: "If-Range")
            let (response, stream) = try await DataTaskStream.start(request, session: session)
            try RangeFetcher.validate(response, identity: identity, start: position)
            passthrough = stream
        }
        guard let chunk = try await passthrough?.nextChunk() else { throw RangeFetchError.shortBody }
        let usable = chunk.prefix(Int(window.end - position + 1))
        position += Int64(usable.count)
        return usable
    }
}
