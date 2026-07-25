import Foundation

/// A permutation of `0..<count`, for `VideoPlayerView`'s randomize mode.
///
/// `pinFirst` forces that index to the front — used when building the
/// initial order so the tapped video plays first. `avoidFirst` prevents
/// that index from landing first — used when reshuffling after the
/// sequence is exhausted, so autoplay's loop never repeats the
/// just-finished video back-to-back. At most one of the two matters per
/// call (`pinFirst` wins if both are passed); neither applies when
/// `count <= 1`, since there is no alternative front position.
public func shuffledPlaybackOrder<G: RandomNumberGenerator>(
    count: Int,
    pinFirst: Int? = nil,
    avoidFirst: Int? = nil,
    using rng: inout G
) -> [Int] {
    guard count > 0 else { return [] }
    var order = Array(0..<count).shuffled(using: &rng)
    if let pinFirst, let at = order.firstIndex(of: pinFirst) {
        order.remove(at: at)
        order.insert(pinFirst, at: 0)
    } else if count > 1, let avoidFirst, order.first == avoidFirst {
        order.swapAt(0, 1)
    }
    return order
}

/// Convenience overload using the system RNG (production call sites).
public func shuffledPlaybackOrder(
    count: Int,
    pinFirst: Int? = nil,
    avoidFirst: Int? = nil
) -> [Int] {
    var rng = SystemRandomNumberGenerator()
    return shuffledPlaybackOrder(count: count, pinFirst: pinFirst, avoidFirst: avoidFirst, using: &rng)
}
