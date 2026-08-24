import Foundation

/// Queue stepping for a playback session: which video comes next, sequentially
/// or randomly, skipping entries with no playable source.
///
/// Extracted from `VideoPlayerView`, where these rules lived as private methods
/// on a SwiftUI view and could not be tested. `isPlayable` is injected so this
/// type never imports AVFoundation — the caller decides what "playable" means
/// (see `PlaybackSource` in the app target).
///
/// Not `Sendable`: it stores `isPlayable`. Callers are `@MainActor`.
public struct QueueNavigator {
    public let videos: [Video]
    public let randomize: Bool
    private let isPlayable: (Video) -> Bool
    public private(set) var currentIndex: Int
    /// Random mode only: cursor state over a shuffled permutation of the
    /// playable pool, grown with a fresh shuffle whenever a forward step runs
    /// off the end. Stays empty when `randomize` is false.
    private var playbackOrder: [Int] = []
    private var orderPosition: Int = 0

    public init(videos: [Video], startIndex: Int, randomize: Bool,
                isPlayable: @escaping (Video) -> Bool) {
        self.videos = videos
        self.randomize = randomize
        self.isPlayable = isPlayable
        self.currentIndex = startIndex
        guard randomize else { return }
        let playable = playableVideoIndices
        let order = shuffledPlaybackOrder(count: playable.count,
                                          pinFirst: playable.firstIndex(of: startIndex))
        playbackOrder = order.map { playable[$0] }
        orderPosition = 0
    }

    public var currentVideo: Video? {
        videos.indices.contains(currentIndex) ? videos[currentIndex] : nil
    }

    /// Whether at least one video in the queue has a playable source. In random
    /// mode a literal end-of-list peek doesn't apply (the order reshuffles
    /// forever), so this is what decides the lock screen's "next" enabled state.
    public var hasAnyPlayable: Bool { videos.contains(where: isPlayable) }

    /// Nothing before the current item: the cursor is at random-order position
    /// 0, or no playable entry precedes it sequentially. Drives the iOS
    /// "previous restarts the current item" convention.
    public var isAtQueueStart: Bool {
        randomize ? orderPosition == 0 : playableIndex(from: currentIndex, direction: -1) == nil
    }

    /// Move to the next playable video in `direction` and return its `videos`
    /// index, or nil when there is none. **Commits** — in random mode a forward
    /// step mutates the cursor and may reshuffle, so never call it as a peek.
    public mutating func step(direction: Int) -> Int? {
        guard let next = randomize
            ? randomStep(direction: direction)
            : playableIndex(from: currentIndex, direction: direction) else { return nil }
        currentIndex = next
        return next
    }

    /// Whether a forward step would find something, without committing one.
    public mutating func peekHasNext() -> Bool {
        randomize ? hasAnyPlayable : playableIndex(from: currentIndex, direction: 1) != nil
    }

    /// Nearest queue index in `direction` with a playable source, or nil.
    private func playableIndex(from index: Int, direction: Int) -> Int? {
        var i = index + direction
        while videos.indices.contains(i) {
            if isPlayable(videos[i]) { return i }
            i += direction
        }
        return nil
    }

    /// Indices with a playable source — the pool `playbackOrder` is drawn from
    /// and reshuffled over. Excluding unplayable entries here (rather than
    /// skipping them while stepping) keeps `orderPosition == 0` an accurate
    /// "nothing before me" check.
    private var playableVideoIndices: [Int] {
        videos.indices.filter { isPlayable(videos[$0]) }
    }

    /// Random-mode step: walks `playbackOrder`'s cursor. Forward, grows the
    /// order with a fresh reshuffle over the currently playable pool — excluding
    /// the wrap point, so autoplay's loop never repeats a video back-to-back —
    /// whenever the step runs off the end.
    private mutating func randomStep(direction: Int) -> Int? {
        if direction > 0 {
            let nextPosition = orderPosition + 1
            if nextPosition >= playbackOrder.count {
                let playable = playableVideoIndices
                guard !playable.isEmpty else { return nil }
                let avoidPosition = playbackOrder.last.flatMap { playable.firstIndex(of: $0) }
                playbackOrder += shuffledPlaybackOrder(count: playable.count,
                                                       avoidFirst: avoidPosition)
                    .map { playable[$0] }
            }
            guard nextPosition < playbackOrder.count else { return nil }
            orderPosition = nextPosition
            return playbackOrder[nextPosition]
        } else {
            guard orderPosition > 0 else { return nil }
            orderPosition -= 1
            return playbackOrder[orderPosition]
        }
    }
}
