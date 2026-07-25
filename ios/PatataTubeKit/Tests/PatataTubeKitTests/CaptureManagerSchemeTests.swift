import Foundation
import Testing
@testable import PatataTubeKit

@Suite("Capture manager scheme swap")
struct CaptureManagerSchemeTests {
    @Test func swapsSchemeToPrivateAndBack() throws {
        let remote = URL(string: "https://srv.test/videos/7/stream?version_id=3")!
        let capture = try #require(CaptureManager.captureURL(from: remote))
        #expect(capture.scheme == "ptcapture")
        #expect(capture.absoluteString == "ptcapture://srv.test/videos/7/stream?version_id=3")
        let back = try #require(CaptureManager.remoteURL(from: capture))
        #expect(back == remote)
    }
}
