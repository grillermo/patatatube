import Foundation

/// Whether dismissing the full-screen player should hand playback back to the
/// audio-only mini player.
///
/// The mini player's thumbnail/title tap opens the full-screen player through
/// `PiPSession.restoreFullScreen`, which stops the audio queue. Closing that
/// player should put the user back where they were — same track, same second —
/// rather than ending a session they never asked to end. A player reached any
/// other way (a grid tap, a PiP float's restore button) has no audio session
/// behind it and must not start one on the way out.
///
/// - Parameters:
///   - cameFromAudio: the cover was opened by the audio mini player.
///   - isHandingOff: PiP is taking the player over; the video keeps playing in
///     the float, so there is nothing to hand back.
///   - reachedEnd: the item played to its end (an autoplay-off self-dismiss, or
///     sleep mode). Handing back there would restart the finished track.
public func shouldReturnToAudio(cameFromAudio: Bool, isHandingOff: Bool, reachedEnd: Bool) -> Bool {
    cameFromAudio && !isHandingOff && !reachedEnd
}
