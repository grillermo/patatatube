import Foundation

/// Playback to reopen at launch, already matched against the loaded list.
public struct ResolvedPlayer: Equatable, Sendable {
    public var video: Video
    public var queue: [Video]
    public var sleepMode: Bool

    public init(video: Video, queue: [Video], sleepMode: Bool) {
        self.video = video
        self.queue = queue
        self.sleepMode = sleepMode
    }
}

public struct ResolvedRestoration: Equatable, Sendable {
    public var path: [Route]
    public var search: String
    public var player: ResolvedPlayer?

    public init(path: [Route], search: String, player: ResolvedPlayer?) {
        self.path = path
        self.search = search
        self.player = player
    }
}

/// Turns a persisted `RestorationState` plus the loaded video list into
/// something the grid can apply directly.
///
/// Pure by design: the app target has no test coverage, so every restoration
/// rule that could be wrong lives here where `swift test` can reach it.
public enum RestorationResolver {
    public static func resolve(
        state: RestorationState,
        videos: [Video],
        hasPendingQuickAction: Bool
    ) -> ResolvedRestoration {
        ResolvedRestoration(
            path: state.path,
            search: state.search,
            player: hasPendingQuickAction
                ? nil
                : resolvePlayer(state.player, videos: videos)
        )
    }

    private static func resolvePlayer(
        _ player: PlayerState?,
        videos: [Video]
    ) -> ResolvedPlayer? {
        guard let player else { return nil }

        // The queue is rebuilt, never persisted: whatever list the restored
        // screen shows is the list the player queues over.
        guard let video = videos.first(where: { $0.id == player.videoID }) else { return nil }
        return ResolvedPlayer(video: video, queue: videos, sleepMode: player.sleepMode)
    }
}
