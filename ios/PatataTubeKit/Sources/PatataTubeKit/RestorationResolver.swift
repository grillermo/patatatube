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
        let shows = ShowGroup.group(videos)
        var path: [Route] = []

        // A route that no longer resolves takes the rest of the stack with it:
        // whatever was pushed from inside it is unreachable now.
        for route in state.path {
            switch route {
            case .group:
                break
            case .show(let title):
                guard shows.contains(where: { $0.id == title }) else {
                    return finish(path: path, state: state, videos: videos,
                                  shows: shows, hasPendingQuickAction: hasPendingQuickAction)
                }
            case .movie(let id):
                guard videos.contains(where: { $0.id == id }) else {
                    return finish(path: path, state: state, videos: videos,
                                  shows: shows, hasPendingQuickAction: hasPendingQuickAction)
                }
            case .downloads:
                break
            }
            path.append(route)
        }

        return finish(path: path, state: state, videos: videos,
                      shows: shows, hasPendingQuickAction: hasPendingQuickAction)
    }

    private static func finish(
        path: [Route],
        state: RestorationState,
        videos: [Video],
        shows: [ShowGroup],
        hasPendingQuickAction: Bool
    ) -> ResolvedRestoration {
        ResolvedRestoration(
            path: path,
            search: state.search,
            player: hasPendingQuickAction
                ? nil
                : resolvePlayer(state.player, path: path, videos: videos, shows: shows)
        )
    }

    private static func resolvePlayer(
        _ player: PlayerState?,
        path: [Route],
        videos: [Video],
        shows: [ShowGroup]
    ) -> ResolvedPlayer? {
        guard let player else { return nil }

        // The queue is rebuilt, never persisted: whatever list the restored
        // screen shows is the list the player queues over.
        var queue = videos
        for case .show(let title) in path.reversed() {
            if let show = shows.first(where: { $0.id == title }) {
                queue = show.episodes
            }
            break
        }

        guard let video = queue.first(where: { $0.id == player.videoID }) else { return nil }
        return ResolvedPlayer(video: video, queue: queue, sleepMode: player.sleepMode)
    }
}
