import PatataTubeKit
import SwiftUI
import Testing
@testable import PatataTube

@Suite("Video row audio overlay", .serialized)
@MainActor
struct VideoRowAudioTests {
    @Test func idleDrawsNoOverlayGlyph() {
        #expect(RowAudioState.idle.overlaySystemImage == nil)
    }

    @Test func playingDrawsPauseAndPausedDrawsPlay() {
        // The glyph is the *action* the next tap performs, not the current state.
        #expect(RowAudioState.playing.overlaySystemImage == "pause.fill")
        #expect(RowAudioState.paused.overlaySystemImage == "play.fill")
    }

    @Test func loadingDrawsNoGlyphBecauseItShowsASpinner() {
        #expect(RowAudioState.loading.overlaySystemImage == nil)
    }

    @Test func rowRendersWithEveryAudioState() throws {
        for state in [RowAudioState.idle, .loading, .playing, .paused] {
            let row = VideoRow(
                video: Self.video, cacheState: .notCached,
                currentCacheState: { .notCached }, groups: [],
                audioState: state,
                onPlay: {}, onPlaySleep: {}, onDownload: { true }, onCancel: {},
                onDeleteCache: {}, onSetGroup: { _ in }, onPromote: { _ in },
                onChooseVersion: { _ in }, onDelete: {}
            )
            #expect(row.audioState == state)
        }
    }

    static let video = Video(
        id: 42, url: "/videos/42", title: "Video 42", platform: nil, sourceKey: nil,
        previewUrl: nil, groupID: 1, plexKind: nil, position: nil, status: "done",
        errorMsg: nil, streamPath: "/videos/42/stream"
    )
}
