import Foundation

/// The cache key of a video or one of its versions (`812`, `812:3`), and the
/// names derived from it. One key is one `MediaStore` entry and one finished
/// file in the videos root.
enum MediaKey {
    static func key(videoId: Int, versionId: Int?) -> String {
        versionId.map { "\(videoId):\($0)" } ?? "\(videoId)"
    }

    static func videoId(of key: String) -> Int {
        Int(key.split(separator: ":").first ?? "") ?? 0
    }

    static func versionId(of key: String) -> Int? {
        let parts = key.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// `812.mp4` or `812.v3.mp4`, the name `CacheManager.localURL` has always used.
    static func finishedFilename(_ key: String) -> String {
        if let versionId = versionId(of: key) {
            return "\(videoId(of: key)).v\(versionId).mp4"
        }
        return "\(videoId(of: key)).mp4"
    }
}
