import Testing
import Foundation
@testable import PatataTubeKit

private let sampleJSON = """
[
  {"id": 7, "url": "https://youtu.be/abc", "title": "Hi", "platform": "youtube",
   "source_key": "abc12345678", "preview_url": "https://img/abc.jpg",
   "classification": "children", "position": 3, "status": "completed",
   "error_msg": null, "stream_path": "/videos/7/stream"},
  {"id": 8, "url": "https://x/y", "title": null, "platform": null,
   "source_key": null, "preview_url": null, "classification": "adults",
   "position": null, "status": "pending", "error_msg": "boom",
   "stream_path": "/videos/8/stream"}
]
""".data(using: .utf8)!

@Test func decodesVideoArrayWithSnakeCase() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let videos = try decoder.decode([Video].self, from: sampleJSON)

    #expect(videos.count == 2)
    #expect(videos[0].id == 7)
    #expect(videos[0].previewUrl == "https://img/abc.jpg")
    #expect(videos[0].sourceKey == "abc12345678")
    #expect(videos[0].streamPath == "/videos/7/stream")
    #expect(videos[1].title == nil)
    #expect(videos[1].position == nil)
    #expect(videos[1].errorMsg == "boom")
}

@Test func withClassificationReplacesOnlyClassification() {
    let v = Video(id: 1, url: "u", title: "t", platform: nil, sourceKey: nil,
                  previewUrl: nil, classification: "children", position: 1,
                  status: "completed", errorMsg: nil, streamPath: "/videos/1/stream")
    let updated = v.withClassification("adults")
    #expect(updated.classification == "adults")
    #expect(updated.id == 1)
    #expect(updated.status == "completed")
}
