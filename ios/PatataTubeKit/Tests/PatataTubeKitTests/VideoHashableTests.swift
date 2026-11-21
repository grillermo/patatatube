import XCTest
@testable import PatataTubeKit

final class VideoHashableTests: XCTestCase {
    func testVideoIsHashable() {
        let video = Video(id: 1, url: "https://example.com", title: "A Video",
                          platform: nil, sourceKey: nil, previewUrl: nil,
                          groupID: nil, position: nil, status: "done",
                          errorMsg: nil, streamPath: "/videos/1/stream",
                          hlsPath: "/videos/1/hls/master.m3u8")
        XCTAssertEqual(Set([video, video]).count, 1)
    }
}
