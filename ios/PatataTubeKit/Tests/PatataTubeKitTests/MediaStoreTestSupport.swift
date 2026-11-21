import Foundation
import Testing
@testable import PatataTubeKit

/// Deterministic bytes, so a reassembled file can be compared to its source.
func sampleBody(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}

func temporaryVideosRoot(_ label: String = "store") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
}

/// Settable clock for LRU tests.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// Claims `range`, writes `body[range]` into data.bin and commits it, the way
/// a fetcher would, then releases the claim.
func put(
    _ store: MediaStore,
    key: String,
    _ range: DownloadByteRange,
    generation: Int,
    from body: Data
) async throws {
    guard case .granted(let claim) = await store.claim(
        key: key, from: range.start, through: range.end, owner: .download, waitWithin: 0
    ), claim.end == range.end else {
        Issue.record("store refused to claim \(range)")
        return
    }
    let handle = try FileHandle(forWritingTo: store.dataURL(key: key))
    try handle.seek(toOffset: UInt64(range.start))
    try handle.write(contentsOf: body.subdata(in: Int(range.start)..<Int(range.end + 1)))
    try handle.close()
    _ = try await store.commit(key: key, claim: claim.id, generation: generation, through: range.end)
    await store.releaseClaim(key: key, id: claim.id)
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
