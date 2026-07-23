import Foundation

struct DownloadStreamSettings {
    static let key = "downloadStreamCount"
    static let defaultCount = 2
    static let allowedCounts = 1...4

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Int {
        guard defaults.object(forKey: Self.key) != nil else {
            return Self.defaultCount
        }

        return min(
            max(defaults.integer(forKey: Self.key), Self.allowedCounts.lowerBound),
            Self.allowedCounts.upperBound
        )
    }

    func save(_ count: Int) {
        let clamped = min(
            max(count, Self.allowedCounts.lowerBound),
            Self.allowedCounts.upperBound
        )
        defaults.set(clamped, forKey: Self.key)
    }
}
