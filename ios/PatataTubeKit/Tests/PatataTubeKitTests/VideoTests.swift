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

@Test func testDecodesLibraryFields() throws {
    let json = """
    {"id": 7, "url": "/vol/ep.mkv", "title": "System", "platform": null,
     "source_key": null, "preview_url": "/videos/7/preview",
     "classification": "tv", "position": 3, "status": "unconverted",
     "error_msg": null, "stream_path": "/videos/7/stream",
     "source": "library", "show_title": "The Bear", "season": 1,
     "episode": 1, "summary": "Carmy.", "show_preview_url": "/videos/7/preview?kind=show"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: json)
    #expect(video.source == "library")
    #expect(video.isLibrary == true)
    #expect(video.showTitle == "The Bear")
    #expect(video.season == 1)
    #expect(video.episode == 1)
    #expect(video.summary == "Carmy.")
    #expect(video.showPreviewUrl == "/videos/7/preview?kind=show")
}

@Test func testDecodesLegacyPayloadWithoutLibraryFields() throws {
    let json = """
    {"id": 1, "url": "https://x.com/s/1", "title": null, "platform": "twitter",
     "source_key": null, "preview_url": null, "classification": "children",
     "position": 1, "status": "done", "error_msg": null,
     "stream_path": "/videos/1/stream"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: json)
    #expect(video.source == nil)
    #expect(video.isLibrary == false)
}

@Test func decodesAudioMetadataAndDefaultsLegacyVersions() throws {
    let json = """
    {"id": 1, "url": "u", "title": null, "platform": null,
     "source_key": null, "preview_url": null, "classification": "children",
     "position": 1, "status": "done", "error_msg": null,
     "stream_path": "/videos/1/stream", "audio_lang": "es",
     "versions": [{"id": 2, "label": "HD", "status": "done", "is_chosen": true},
                  {"id": 3, "label": null, "status": "done", "is_chosen": false,
                   "audio_tracks": [{"lang": "en", "title": "English", "available": true}]}]}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let video = try decoder.decode(Video.self, from: json)

    #expect(video.audioLang == "es")
    #expect(video.versions[0].audioTracks.isEmpty)
    #expect(video.versions[1].audioTracks == [AudioTrack(lang: "en", title: "English", available: true)])
    #expect(video.withAudioLang("fr").audioLang == "fr")
}
