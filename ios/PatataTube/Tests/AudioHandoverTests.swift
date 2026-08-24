import AVKit
import PatataTubeKit
import Testing
@testable import PatataTube

private func video(_ id: Int) -> Video {
    Video(
        id: id, url: "/videos/\(id)", title: "Video \(id)", platform: nil,
        sourceKey: nil, previewUrl: nil, groupID: 7, plexKind: nil,
        position: id, status: "done", errorMsg: nil,
        streamPath: "/videos/\(id)/stream"
    )
}

/// A player over a URL that will never load. Nothing here waits on playback —
/// what is under test is ownership, not decoding — and `play()` still moves
/// `timeControlStatus` off `.paused`, which is the state the handover reads.
private func livePlayer() -> AVPlayer {
    AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null/never.mp4")))
}

/// The audio mini player and the full-screen cover pass one `AVPlayer` back and
/// forth: the bar's thumbnail tap hands its player to the cover, and dismissing
/// that cover hands it back. The point of both is that the sound never stops,
/// so what is asserted throughout is that the *same* running player is carried
/// across — not rebuilt, not paused, not re-sought.
@Suite("Audio player handover", .serialized)
@MainActor
struct AudioHandoverTests {
    @Test func adoptingAPlayingPlayerLeavesItPlaying() {
        let model = AppModel()
        let player = livePlayer()
        player.play()

        model.audio.adopt(player: player, videos: [video(1), video(2)], startIndex: 1,
                          scope: "group:7", sleepMode: false, model: model)

        // The regression this guards: the old handback paused this player and
        // built a fresh one, which is the gap the user hears.
        #expect(player.timeControlStatus != .paused)
        #expect(model.audio.isPlaying)
        #expect(model.audio.currentID == 2)
        #expect(model.audio.currentScope == "group:7")
        model.audio.stop()
    }

    /// Identity, not just state: the queue's transport has to drive the very
    /// player that was handed over, or the bar would be controlling a ghost.
    @Test func theAdoptedPlayerIsTheOneTheQueueControls() {
        let model = AppModel()
        let player = livePlayer()
        player.play()

        model.audio.adopt(player: player, videos: [video(1)], startIndex: 0,
                          scope: nil, sleepMode: false, model: model)
        model.audio.toggle()

        #expect(player.timeControlStatus == .paused)
        model.audio.stop()
    }

    /// A video paused at dismiss comes back as a paused bar — no `play()` of
    /// our own, the rate is whatever the user left it at.
    @Test func adoptingAPausedPlayerHandsBackPaused() {
        let model = AppModel()
        let player = livePlayer()

        model.audio.adopt(player: player, videos: [video(3)], startIndex: 0,
                          scope: nil, sleepMode: false, model: model)

        #expect(player.timeControlStatus == .paused)
        #expect(!model.audio.isPlaying)
        #expect(model.audio.currentID == 3)
        model.audio.stop()
    }

    @Test func adoptingWithAnIndexOutsideTheQueueStartsNothing() {
        let model = AppModel()

        model.audio.adopt(player: livePlayer(), videos: [video(1)], startIndex: 4,
                          scope: nil, sleepMode: false, model: model)

        #expect(model.audio.currentID == nil)
        #expect(!model.audio.isPlaying)
    }

    // MARK: - Opening full screen from the bar

    /// The other half of the round trip: the bar's thumbnail tap gives the
    /// cover the player it is already using, so opening full screen doesn't
    /// rebuild the item either.
    @Test func openingFullScreenHandsTheLivePlayerToThePresentation() {
        let model = AppModel()
        let player = livePlayer()
        player.play()
        model.audio.adopt(player: player, videos: [video(1), video(2)], startIndex: 0,
                          scope: "group:7", sleepMode: false, model: model)

        model.audio.openFullScreen()

        #expect(model.pip.restoreAdoptedPlayer === player)
        #expect(model.pip.restoreCameFromAudio)
        #expect(model.pip.restoreRequest?.id == 1)
        #expect(model.pip.restoreRequest?.videos.count == 2)
        // Handed over, not stopped: this is the whole point.
        #expect(player.timeControlStatus != .paused)
        // ...and the queue has let go, so the bar drops away with nothing to stop.
        #expect(model.audio.currentID == nil)
        #expect(!model.audio.isPlaying)
        model.pip.restoreRequest = nil
        _ = model.pip.takeAdoptedPlayer()
        player.pause()
    }

    /// `RootTabView` stops the audio queue on every restore request. After a
    /// handover there is nothing left to stop — and nothing to release, since
    /// the audio session now belongs to the cover that is opening.
    @Test func stoppingAnAlreadyHandedOverQueueLeavesThePlayerAlone() {
        let model = AppModel()
        let player = livePlayer()
        player.play()
        model.audio.adopt(player: player, videos: [video(1)], startIndex: 0,
                          scope: nil, sleepMode: false, model: model)
        let handedOver = model.audio.relinquishPlayer()

        model.audio.stop()

        #expect(handedOver === player)
        #expect(player.timeControlStatus != .paused)
        handedOver?.pause()
    }

    @Test func relinquishingAnIdleQueueHandsOverNothing() {
        let model = AppModel()
        #expect(model.audio.relinquishPlayer() == nil)
    }

    @Test func takingTheHandedOverPlayerIsConsuming() {
        let sut = PiPSession()
        let player = livePlayer()
        sut.restoreFullScreen(video: video(1), queueSnapshot: [video(1)], sleepMode: false,
                              startSecs: 0, scope: nil, randomize: false, adoptedPlayer: player)

        #expect(sut.takeAdoptedPlayer() === player)
        #expect(sut.takeAdoptedPlayer() == nil)
        #expect(sut.restoreAdoptedPlayer == nil)
    }

    /// A handover nothing adopted is still playing. Dropping the reference
    /// without pausing would leave sound coming out of an object no screen can
    /// reach — so the next restore pauses it on its way past.
    @Test func anUnclaimedHandoverIsPausedByTheNextRestore() {
        let sut = PiPSession()
        let stranded = livePlayer()
        stranded.play()
        sut.restoreFullScreen(video: video(1), queueSnapshot: [video(1)], sleepMode: false,
                              startSecs: 0, scope: nil, randomize: false, adoptedPlayer: stranded)

        sut.restoreFullScreen(video: video(2), queueSnapshot: [video(2)], sleepMode: false,
                              startSecs: 0, scope: nil, randomize: false)

        #expect(stranded.timeControlStatus == .paused)
        #expect(sut.restoreAdoptedPlayer == nil)
    }

    /// The departing `AVPlayerViewController` is retained by `PiPSession` until
    /// the next presentation registers, so the player it was mounted in has to
    /// be taken out of it explicitly — the same detach backgrounding performs.
    @Test func releasingTheControllerDetachesTheHandedOverPlayer() {
        let sut = PiPSession()
        let controller = AVPlayerViewController()
        let player = livePlayer()
        controller.player = player
        sut.register(controller: controller)

        sut.releaseController(for: player)

        #expect(controller.player == nil)
        #expect(player.timeControlStatus == .paused)  // detaching never pauses
    }

    @Test func releasingTheControllerIgnoresADifferentPlayer() {
        let sut = PiPSession()
        let controller = AVPlayerViewController()
        let player = livePlayer()
        controller.player = player
        sut.register(controller: controller)

        sut.releaseController(for: livePlayer())

        #expect(controller.player === player)
    }

    /// While a float is live the controller *is* the playback surface: clearing
    /// its player there would close the float mid-video.
    @Test func releasingTheControllerIsRefusedWhileAFloatIsLive() {
        let sut = PiPSession()
        let controller = AVPlayerViewController()
        let player = livePlayer()
        controller.player = player
        sut.prepare(player: player, positionObserver: nil, videos: [video(1)], index: 0,
                    sleepMode: false, scope: nil, randomize: false, onStart: {})
        sut.register(controller: controller)
        sut.playerViewControllerWillStartPictureInPicture(controller)

        sut.releaseController(for: player)

        #expect(controller.player === player)
    }
}
