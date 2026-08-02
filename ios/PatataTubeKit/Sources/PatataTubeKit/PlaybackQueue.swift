import Foundation

/// Self-contained playback request: the queue snapshot and where to start in it.
/// Built at tap time and presented as a single `fullScreenCover(item:)` value so
/// the player never depends on separate view state that can lag a presentation
/// (an empty side-channel queue crashed the first playback after cold launch).
public struct PlaybackQueue: Identifiable, Equatable, Sendable {
    /// The tapped video's id; identifies the presentation.
    public let id: Int
    public let videos: [Video]
    public let startIndex: Int
    /// When true the player plays only this item and ends in the sleep overlay.
    public let sleepMode: Bool
    /// Where to seek the first item to, in seconds. 0 plays from the start.
    /// Only ever non-zero when the user picked "Resume" — auto-advance inside
    /// the player always starts the next item at 0.
    public let startSecs: Double

    /// `video` may be a fresher copy than its row in `queueSnapshot`
    /// (e.g. updated by ensureReady), so it replaces that row. A video absent
    /// from the snapshot plays as a single-item queue — never empty.
    public init(
        video: Video,
        queueSnapshot: [Video],
        sleepMode: Bool = false,
        startSecs: Double = 0
    ) {
        self.sleepMode = sleepMode
        self.startSecs = startSecs
        self.id = video.id
        if let index = queueSnapshot.firstIndex(where: { $0.id == video.id }) {
            var queue = queueSnapshot
            queue[index] = video
            self.videos = queue
            self.startIndex = index
        } else {
            self.videos = [video]
            self.startIndex = 0
        }
    }
}
