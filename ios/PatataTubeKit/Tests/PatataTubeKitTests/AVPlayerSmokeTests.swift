import AVFoundation
import XCTest
@testable import PatataTubeKit

/// Real AVFoundation (macOS shares the iOS HTTP loader) against the real
/// proxy. Small commits make the playback path cross many commit and read
/// boundaries. This is the reproduction that showed the 8 MB cap failing
/// the item.
@MainActor
final class AVPlayerSmokeTests: XCTestCase {
    func testPlaysThroughTheStreamingProxy() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tiny", withExtension: "mp4", subdirectory: "Fixtures"))
        let body = try Data(contentsOf: fixture)
        MockURLProtocol.stubRanged(path: "/videos/31/stream", fullBody: body, etag: "\"tiny\"")
        defer { MockURLProtocol.reset() }

        let root = temporaryVideosRoot("smoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        var tuning = StreamProxy.Tuning()
        tuning.commitSize = 4096
        tuning.readSize = 4096
        tuning.readAhead = 16 * 1024
        tuning.waitWithin = 4096
        let proxy = StreamProxy(
            store: MediaStore(videosRoot: root),
            credentials: InMemoryCredentialStore(baseURL: URL(string: "https://upstream.test"), token: "tok"),
            session: URLSession(configuration: config),
            tuning: tuning
        )
        await proxy.start()

        let player = AVPlayer(url: try XCTUnwrap(proxy.mp4URL(videoId: 31, versionId: nil)))
        player.isMuted = true
        let ready = await poll { player.currentItem?.status == .readyToPlay }
        XCTAssertTrue(ready, "item status \(player.currentItem?.status.rawValue ?? -1), error \(String(describing: player.currentItem?.error))")
        player.play()
        let advanced = await poll { player.currentTime().seconds > 0.3 }
        XCTAssertTrue(advanced, "playback never advanced")
        player.pause()
        await proxy.stop()
    }

    private func poll(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
