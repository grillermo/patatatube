import XCTest
@testable import PatataTubeKit

final class ResumePositionAPITests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testVideoDecodesResumeSecs() throws {
        let json = """
        {"id": 1, "url": "u", "classification": "movies", "status": "done",
         "stream_path": "/videos/1/stream", "resume_secs": 91.5}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let video = try decoder.decode(Video.self, from: json)
        XCTAssertEqual(video.resumeSecs, 91.5)
    }

    func testVideoResumeSecsDefaultsToZeroWhenMissing() throws {
        let json = """
        {"id": 1, "url": "u", "classification": "movies", "status": "done",
         "stream_path": "/videos/1/stream"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let video = try decoder.decode(Video.self, from: json)
        XCTAssertEqual(video.resumeSecs, 0)
    }

    func testSavePositionPostsSeconds() async throws {
        let (client, recorder) = makeClient(status: 204, body: Data())
        try await client.savePosition(id: 12, secs: 91.5)
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/videos/12/position")
        let body = try XCTUnwrap(recorder.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["secs"] as? Double, 91.5)
    }

    func testSavePositionThrowsOnBadStatus() async {
        let (client, _) = makeClient(status: 500, body: Data())
        do {
            try await client.savePosition(id: 12, secs: 10)
            XCTFail("expected throw")
        } catch let error as APIError {
            XCTAssertEqual(error, APIError.badStatus(500))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func makeClient(status: Int, body: Data) -> (APIClient, RequestRecorder) {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.lastRequest = request
            recorder.lastBody = request.httpBodyData()
            return (jsonResponse(request.url!, status: status), body)
        }
        let store = InMemoryCredentialStore(
            baseURL: URL(string: "https://srv.test")!, token: "tok"
        )
        return (APIClient(store: store, session: mockSession()), recorder)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    var lastRequest: URLRequest?
    var lastBody: Data?
}
