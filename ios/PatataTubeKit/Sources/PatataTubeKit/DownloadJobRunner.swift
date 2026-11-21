import Foundation

struct DownloadTuning: Sendable {
    /// Never split a remainder into pieces smaller than this.
    var minPiece: Int64 = 4 * 1_048_576
    var commitSize = RangeFetcher.defaultCommitSize
    /// 1 + 3 retries in place, per the spec.
    var maxAttempts = 4
}

/// One download's transfer. Probes the identity once per process, then keeps
/// up to `streamCount` fetchers on the entry's holes until the file is
/// promoted. Holes may close under it (someone is watching), and a playback
/// claim's remainder opens up again when that reader goes away; every store
/// change wakes the loop to re-plan.
struct DownloadJobRunner: Sendable {
    static let maxIdentityResets = 2

    let store: MediaStore
    let key: String
    let streamCount: Int
    let session: URLSession
    let upstream: UpstreamRequests
    let tuning: DownloadTuning
    let onProgress: @Sendable (MediaEntryManifest) -> Void

    private enum Event: Sendable {
        case fetcherEnded(Result<FetchOutcome, Error>)
        case storeChanged
    }

    func run() async throws {
        var resets = 0
        while true {
            try Task.checkCancellation()
            if try await store.promoteIfComplete(key: key) { return }
            let (identity, generation) = try await resolveIdentity()
            do {
                try await fill(identity: identity, generation: generation)
                return
            } catch RangeFetchError.entityChanged(let newIdentity) {
                resets += 1
                guard resets <= Self.maxIdentityResets else {
                    throw RangeFetchError.entityChanged(newIdentity)
                }
                DevLog.event(.download, "download restarting: file changed on the server", ["key": key])
                if let newIdentity {
                    _ = try await store.open(key: key, identity: newIdentity)
                } else {
                    await store.invalidate(key: key)
                }
            }
        }
    }

    private func resolveIdentity() async throws -> (MediaIdentity, Int) {
        if let known = await store.verifiedIdentity(key: key) {
            return (known.identity, known.generation)
        }
        let identity = try await IdentityProbe.fetch(upstream.probe(), session: session)
        do {
            return (identity, try await store.open(key: key, identity: identity))
        } catch {
            guard await store.evictForStorageFailure(excluding: key) else { throw error }
            return (identity, try await store.open(key: key, identity: identity))
        }
    }

    private func fill(identity: MediaIdentity, generation: Int) async throws {
        try await withThrowingTaskGroup(of: Event.self) { group in
            defer { group.cancelAll() }
            var running = 0
            var watching = false
            while true {
                if try await store.promoteIfComplete(key: key) { return }
                let seen = await store.version(key: key)
                if let manifest = await store.manifest(key: key) { onProgress(manifest) }
                let claims = await store.claimForDownload(
                    key: key, slots: streamCount - running, minPiece: tuning.minPiece
                )
                for claim in claims {
                    running += 1
                    let fetcher = RangeFetcher(
                        store: store, key: key, identity: identity, generation: generation,
                        session: session, upstream: upstream,
                        commitSize: tuning.commitSize, maxAttempts: tuning.maxAttempts
                    )
                    let store = store
                    let key = key
                    group.addTask {
                        let result: Result<FetchOutcome, Error>
                        do {
                            result = .success(try await fetcher.run(claim: claim.id))
                        } catch {
                            result = .failure(error)
                        }
                        await store.releaseClaim(key: key, id: claim.id)
                        return .fetcherEnded(result)
                    }
                }
                if !watching {
                    watching = true
                    let store = store
                    let key = key
                    group.addTask {
                        await store.waitForChange(key: key, after: seen)
                        return .storeChanged
                    }
                }
                guard let event = try await group.next() else { continue }
                switch event {
                case .storeChanged:
                    watching = false
                case .fetcherEnded(let result):
                    running -= 1
                    switch result {
                    case .success(.promoted):
                        return
                    case .success(.stale):
                        // Reset or deleted under us: re-resolve and start over.
                        throw RangeFetchError.entityChanged(nil)
                    case .success(.finished):
                        break
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }
    }
}
