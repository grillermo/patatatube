import Testing
import Foundation
@testable import PatataTubeKit

private let sampleJSON = """
[
  {"id": 7, "url": "https://youtu.be/abc", "title": "Hi", "platform": "youtube",
   "source_key": "abc12345678", "preview_url": "https://img/abc.jpg",
   "group_id": 1, "position": 3, "status": "completed",
   "error_msg": null, "stream_path": "/videos/7/stream"},
  {"id": 8, "url": "https://x/y", "title": null, "platform": null,
   "source_key": null, "preview_url": null, "group_id": 2,
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

@Test func decodesGroupID() throws {
    let json = #"{"id":1,"url":"u","status":"done","group_id":3}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.groupID == 3)
}



@Test func decodesAnUnsortedVideo() throws {
    let json = #"{"id":3,"url":"u","status":"done"}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.groupID == nil)
}


@Test func testDecodesLegacyPayloadWithoutLibraryFields() throws {
    let json = """
    {"id": 1, "url": "https://x.com/s/1", "title": null, "platform": "twitter",
     "source_key": null, "preview_url": null, "group_id": 1,
     "position": 1, "status": "done", "error_msg": null,
     "stream_path": "/videos/1/stream"}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: json)
    #expect(video.groupID == 1)
}

@Test func decodesALegacyLibraryPayloadWithoutTheRemovedFields() throws {
    // The old backend still sends these until the server cut ships; they must be ignored.
    let json = #"{"id":7,"url":"","status":"done","plex_kind":"tv","show_title":"Bluey","season":1,"episode":2,"versions":[{"id":1,"label":null,"status":"done","is_chosen":true}],"source":"library"}"#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let video = try decoder.decode(Video.self, from: Data(json.utf8))
    #expect(video.id == 7)
}








@Test func decodesTheYouTubeChannel() throws {
    let json = #"{"id":9,"url":"u","status":"done","channel":"Veritasium"}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.channel == "Veritasium")
}

@Test func channelIsNilWhenTheServerOmitsIt() throws {
    // Cached UserDefaults blobs written before the field existed decode too.
    let json = #"{"id":9,"url":"u","status":"done"}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.channel == nil)
}

@Test func copyHelpersCarryTheChannel() throws {
    let json = #"{"id":9,"url":"u","status":"done","channel":"Kurzgesagt"}"#
    let video = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
    #expect(video.withGroupID(4).channel == "Kurzgesagt")
}
