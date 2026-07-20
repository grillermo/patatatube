import PatataTubeKit
import Testing
import ViewInspector
@testable import PatataTube

@MainActor
@Test func videoCellOmitsManualReorderActions() throws {
    let video = Video(
        id: 1,
        url: "https://example.com/video",
        title: "Video",
        platform: nil,
        sourceKey: nil,
        previewUrl: nil,
        classification: "children",
        position: 1,
        status: "done",
        errorMsg: nil,
        streamPath: "/videos/1/stream"
    )
    let sut = VideoCell(
        video: video,
        cacheState: .notCached,
        currentCacheState: { .notCached },
        classifications: ["children", "adults"],
        onPlay: {},
        onDownload: { false },
        onCancel: {},
        onClassify: { _ in },
        onChooseVersion: { _ in },
        onDelete: {}
    )

    #expect(throws: InspectionError.self) {
        _ = try sut.inspect().find(text: "Move up")
    }
    #expect(throws: InspectionError.self) {
        _ = try sut.inspect().find(text: "Move down")
    }
}
