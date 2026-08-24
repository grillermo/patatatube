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

/// Dismissing a full-screen player that was opened from the audio mini player
/// hands playback *back* to the mini player. The point of the handover is that
/// the sound never stops, so what is asserted throughout is that the running
/// `AVPlayer` is carried across — not rebuilt, not paused, not re-sought.
@Suite("Audio handover on dismiss", .serialized)
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
