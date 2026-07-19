import Foundation

/// Process-lifetime cache of raw image bytes keyed by request path, so lazy
/// grids don't re-fetch posters/thumbnails from the server on every scroll.
/// NSCache-backed: evicts automatically under memory pressure.
public final class ImageMemoryCache: @unchecked Sendable {
    public static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, NSData>()

    public init(totalCostLimitBytes: Int = 64 * 1024 * 1024) {
        cache.totalCostLimit = totalCostLimitBytes
    }

    public func data(for key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    public func store(_ data: Data, for key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}
