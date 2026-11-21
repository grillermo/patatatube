import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Data task stream and read-ahead limiter")
struct DataTaskStreamTests {
    private let session = URLSession(configuration: ChunkedRangeProtocol.configuration())

    private func request(_ path: String, range: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://srv.test\(path)")!)
        request.setValue(range, forHTTPHeaderField: "Range")
        return request
    }

    @Test func deliversEveryChunkInOrderThenEnds() async throws {
        let path = "/dts/order"
        let body = sampleBody(1000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"o\"", chunkSize: 100,
            failureError: URLError(.networkConnectionLost), afterChunk: { _ in true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (response, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-999"), session: session)
        #expect(response.statusCode == 206)
        var received = Data()
        for try await chunk in stream { received.append(chunk) }
        #expect(received == body)
    }

    @Test func surfacesAFailureAfterTheBytesThatArrived() async throws {
        let path = "/dts/fail"
        let body = sampleBody(100_000)
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: body, etag: "\"f\"", chunkSize: 10_000,
            failureError: URLError(.networkConnectionLost), afterChunk: { $0 < 30_000 }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (_, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-99999"), session: session)
        var received = Data()
        await #expect(throws: URLError.self) {
            for try await chunk in stream { received.append(chunk) }
        }
        #expect(received == body.prefix(30_000))
    }

    @Test func cancellingStopsTheTransfer() async throws {
        let path = "/dts/cancel"
        ChunkedRangeProtocol.stub(path: path, plan: .init(
            fullBody: sampleBody(100_000), etag: "\"c\"", chunkSize: 1000,
            failureError: URLError(.networkConnectionLost),
            afterChunk: { _ in Thread.sleep(forTimeInterval: 0.005); return true }
        ))
        defer { ChunkedRangeProtocol.reset(path: path) }
        let (_, stream) = try await DataTaskStream.start(request(path, range: "bytes=0-99999"), session: session)
        _ = try await stream.nextChunk()
        stream.cancel()
        #expect(await eventually { ChunkedRangeProtocol.stoppedRanges(path: path) == ["bytes=0-99999"] })
    }

    @Test func limiterParksUntilTheReaderAdvances() async throws {
        let limiter = ReadAheadLimiter(lead: 100, position: 0)
        #expect(limiter.wouldWait(nextByte: 101))
        #expect(!limiter.wouldWait(nextByte: 100))
        let parked = Task { try await limiter.waitForRoom(nextByte: 300); return true }
        try await Task.sleep(for: .milliseconds(20))
        limiter.advance(to: 150)
        try await Task.sleep(for: .milliseconds(20))
        limiter.advance(to: 200)
        #expect(try await parked.value)
    }

    @Test func cancellingTheLimiterReleasesWaiters() async throws {
        let limiter = ReadAheadLimiter(lead: 0, position: 0)
        let parked = Task { try await limiter.waitForRoom(nextByte: 10) }
        try await Task.sleep(for: .milliseconds(20))
        limiter.cancel()
        await #expect(throws: CancellationError.self) { try await parked.value }
    }
}
