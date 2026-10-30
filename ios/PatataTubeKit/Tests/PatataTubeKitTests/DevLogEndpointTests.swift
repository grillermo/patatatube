// ios/PatataTubeKit/Tests/PatataTubeKitTests/DevLogEndpointTests.swift
import XCTest
@testable import PatataTubeKit

final class DevLogEndpointTests: XCTestCase {
    func testURLFromInfoDictionary() {
        let info: [String: Any] = [DevLogEndpoint.urlInfoKey: "http://mac.local:19485/api/devlog"]
        XCTAssertEqual(DevLogEndpoint.url(infoDictionary: info), URL(string: "http://mac.local:19485/api/devlog"))
    }

    func testNoURLWithoutTheFlag() {
        XCTAssertNil(DevLogEndpoint.url(infoDictionary: [DevLogEndpoint.urlInfoKey: ""]))
        XCTAssertNil(DevLogEndpoint.url(infoDictionary: [DevLogEndpoint.urlInfoKey: "$(PATATATUBE_DEVLOG_URL)"]))
        XCTAssertNil(DevLogEndpoint.url(infoDictionary: [DevLogEndpoint.urlInfoKey: "ftp://mac.local/x"]))
        XCTAssertNil(DevLogEndpoint.url(infoDictionary: nil))
    }

    func testBuildString() {
        let info: [String: Any] = ["CFBundleShortVersionString": "2.7.29", "CFBundleVersion": "211"]
        XCTAssertEqual(DevLogEndpoint.build(infoDictionary: info), "2.7.29 (211)")
        XCTAssertEqual(DevLogEndpoint.build(infoDictionary: nil), "? (?)")
    }

    func testRecordLineCarriesBuild() throws {
        let record = DevLogRecord(ts: Date(timeIntervalSince1970: 0), seq: 1, session: "S", kind: .state,
                                  msg: "m", src: "f:1", fn: "f()", meta: [:], build: "2.7.29 (211)")
        let data = try XCTUnwrap(record.jsonLine(using: DevLogEncoding.makeEncoder()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["build"] as? String, "2.7.29 (211)")
    }

    func testCoreStampsBuildOnEveryRecord() {
        let core = DevLogCore(session: "S")
        core.configure(build: "2.7.29 (211)")
        let sink = CollectingSink()
        core.install(sink: sink)
        core.emit(kind: .state, message: "m", meta: [:], file: "F", line: 1, function: "f()")
        core.drainAndWrite()
        XCTAssertEqual(sink.records.map(\.build), ["2.7.29 (211)"])
    }

    func testFixedEndpointWinsOverBackendCredentials() {
        let core = DevLogCore(session: "S")
        let fixed = URL(string: "http://mac.local:19485/api/devlog")!
        core.connectEndpoint(fixed)
        core.connectHTTP(baseURL: URL(string: "https://backend.test")!, token: "t")
        XCTAssertEqual(core.httpEndpointForTesting, fixed)
    }

    func testBackendCredentialsStillWorkWithoutAFixedEndpoint() {
        let core = DevLogCore(session: "S")
        core.connectHTTP(baseURL: URL(string: "https://backend.test")!, token: "t")
        XCTAssertEqual(core.httpEndpointForTesting, URL(string: "https://backend.test/api/devlog"))
    }
}

private final class CollectingSink: DevLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DevLogRecord] = []
    var records: [DevLogRecord] { lock.withLock { stored } }
    func write(_ records: [DevLogRecord]) { lock.withLock { stored += records } }
}
