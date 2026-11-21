// ios/PatataTube/Sources/RootTabView.swift
import SwiftUI
import PatataTubeKit

/// The app's root: the Videos grid with its own navigation stack, and the
/// audio mini player docked under it.
struct RootTabView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoGridView(groups: model.groups, api: model.api)
            AudioMiniPlayerBar(audio: model.audio)
        }
        // The restore button on the PiP float re-opens the full-screen player.
        .modifier(PictureInPictureRestoreCover(pip: model.pip, audio: model.audio))
        // Covers the grid and the mini player bar alike. An open full-screen
        // player draws its own copy above this one.
        .overlay {
            if model.sleepScreenShown {
                SleepScreen { model.sleepScreenShown = false }
            }
        }
    }

    /// Separate so the session is observed: `AppModel` doesn't republish when
    /// its `PiPSession` changes, so `RootTabView` alone would never re-render.
    private struct PictureInPictureRestoreCover: ViewModifier {
        @ObservedObject var pip: PiPSession
        let audio: AudioQueuePlayer

        func body(content: Content) -> some View {
            content
                // A second full-screen-player presentation site (Task 6 only
                // covered the grid's own `startPlayback`), so the "one audio
                // source at a time" constraint has to be enforced here too:
                // list audio may have started while the PiP float was up.
                // The audio-only queue has already let go by the time it asks
                // for a cover (`relinquishPlayer`), so this stops nothing in
                // that case — and `stop()` knows not to release an audio
                // session it no longer owns. It still matters for the PiP
                // float's restore, where list audio may have started
                // underneath it.
                .onChange(of: pip.restoreRequest) { _, newValue in
                    guard newValue != nil else { return }
                    audio.stop()
                }
                .fullScreenCover(item: $pip.restoreRequest) { request in
                    VideoPlayerView(
                        videos: request.videos, startIndex: request.startIndex,
                        sleepMode: request.sleepMode, randomize: pip.restoreRandomize,
                        startSecs: request.startSecs, autoplayScope: pip.restoreScope,
                        returnsToAudio: pip.restoreCameFromAudio,
                        // Read, not taken: this closure can run more than once
                        // for one presentation, and a second pass handing the
                        // view nil would strand a playing player. `setup`
                        // consumes it, exactly once.
                        adoptedPlayer: pip.restoreAdoptedPlayer
                    )
                }
        }
    }

}
