// ios/PatataTubeKit/Tests/PatataTubeKitTests/DevLogUploaderTests.swift
import XCTest
@testable import PatataTubeKit

/// Captures request URLs and never answers, so uploads stay in flight.
private final class HangingProtocol: URLProtocol {
    nonisolated(unsafe) private static var urls: [URL] = []
    private static let lock = NSLock()
    static func reset() { lock.withLock { urls = [] } }
    static var captured: [URL] { lock.withLock { urls } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.urls.append(request.url!) } }
    override func stopLoading() {}
}

final class DevLogUploaderTests: XCTestCase {
    private func makeUploader() -> DevLogUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        return DevLogUploader(endpoint: URL(string: "http://mac.local:19485/api/devlog")!, configuration: config)
    }

    /// Other tests leave uploads hanging, and those can reach the shared
    /// protocol after `reset()`, so wait for this test's own request by name.
    private func waitForRequest(named name: String) -> URL? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let url = HangingProtocol.captured.first(where: { $0.query == "name=\(name)" }) { return url }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return nil
    }

    func testPostsToUploadPathWithName() throws {
        HangingProtocol.reset()
        let uploader = makeUploader()
        XCTAssertTrue(uploader.upload(name: "screen-1.png", data: Data([1, 2, 3])))
        let url = try XCTUnwrap(waitForRequest(named: "screen-1.png"))
        XCTAssertEqual(url.path, "/api/devlog/upload")
        XCTAssertEqual(url.query, "name=screen-1.png")
    }

    func testDropsUploadsPastTheInFlightCap() {
        HangingProtocol.reset()
        let uploader = makeUploader()
        let accepted = (0..<(DevLogUploader.maxInFlight + 2)).map { uploader.upload(name: "f\($0)", data: Data([0])) }
        XCTAssertEqual(accepted.filter { $0 }.count, DevLogUploader.maxInFlight)
        XCTAssertEqual(accepted.last, false)
    }

    func testDropsOversizeFiles() {
        HangingProtocol.reset()
        let big = Data(count: DevLogUploader.maxBytes + 1)
        XCTAssertFalse(makeUploader().upload(name: "big", data: big))
    }
}
