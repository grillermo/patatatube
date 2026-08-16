import AVKit
import PatataTubeKit
import Testing
@testable import PatataTube

private func video(_ id: Int) -> Video {
    Video(
        id: id, url: "/videos/\(id)", title: "Video \(id)", platform: nil,
        sourceKey: nil, previewUrl: nil, groupID: nil, plexKind: .movies,
        position: id, status: "done", errorMsg: nil,
        streamPath: "/videos/\(id)/stream"
    )
}

/// PiP is started by AVKit's own button, which gives no warning — so what is
/// tested here is the handoff: the cover being dismissed, and the queue snapshot
/// staged beforehand being what the float restores from.
@Suite("Picture in Picture handoff")
@MainActor
struct PiPSessionTests {
    private func staged(_ sut: PiPSession, index: Int = 1, onStart: @escaping () -> Void = {}) {
        sut.prepare(
            player: AVPlayer(), positionObserver: nil, videos: [video(1), video(2)],
            index: index, sleepMode: false, scope: "plex:movies", randomize: true,
            onStart: onStart
        )
    }

    @Test func startingPipDismissesTheCoverExactlyOnce() {
        var dismissals = 0
        let sut = PiPSession()
        staged(sut) { dismissals += 1 }

        sut.playerViewControllerDidStartPictureInPicture(AVPlayerViewController())
        #expect(sut.isActive)
        #expect(dismissals == 1)

        sut.playerViewControllerDidStartPictureInPicture(AVPlayerViewController())
        #expect(dismissals == 1)
    }

    @Test func restoreRebuildsTheQueueAtTheFloatingVideo() {
        let sut = PiPSession()
        staged(sut, index: 1)
        sut.playerViewControllerDidStartPictureInPicture(AVPlayerViewController())

        var restored: Bool?
        sut.playerViewController(
            AVPlayerViewController(),
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 }
        )

        #expect(restored == true)
        let request = try? #require(sut.restoreRequest)
        #expect(request?.id == 2)
        #expect(request?.videos.count == 2)
        // The restored presentation needs both, and PlaybackQueue carries neither.
        #expect(sut.restoreScope == "plex:movies")
        #expect(sut.restoreRandomize)
        // Released by the restore itself, so the incoming player view's own
        // controller isn't dropped on top of a live one.
        #expect(!sut.isActive)
    }

    @Test func restoreIsRefusedWhenNothingWasStaged() {
        let sut = PiPSession()
        var restored: Bool?
        sut.playerViewController(
            AVPlayerViewController(),
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 }
        )

        #expect(restored == false)
        #expect(sut.restoreRequest == nil)
    }

    @Test func closingTheFloatEndsTheSessionWithoutARestore() {
        let sut = PiPSession()
        staged(sut)
        sut.playerViewControllerDidStartPictureInPicture(AVPlayerViewController())

        sut.playerViewControllerDidStopPictureInPicture(AVPlayerViewController())

        #expect(!sut.isActive)
        #expect(sut.restoreRequest == nil)
    }

    @Test func aLiveFloatIsNeverRestagedByThePlayerUnderneath() {
        var dismissals = 0
        let sut = PiPSession()
        staged(sut, index: 1) { dismissals += 1 }
        sut.playerViewControllerDidStartPictureInPicture(AVPlayerViewController())

        // A player view mounting behind the float must not steal the handoff.
        staged(sut, index: 0) { dismissals += 1 }
        sut.playerViewController(
            AVPlayerViewController(),
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { _ in }
        )

        #expect(sut.restoreRequest?.id == 2)
        #expect(dismissals == 1)
    }
}
