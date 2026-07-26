import Foundation

/// Size cap for the temporary watch cache, in bytes. Stored as bytes so the
/// cache layer needs no unit conversion; edited in whole gigabytes in Settings.
struct HLSCacheSizeSettings {
    static let key = "hlsTempCacheCapBytes"
    static let bytesPerGigabyte: Int64 = 1_073_741_824
    static let defaultGigabytes = 10
    static let allowedGigabytes = 1...200
    static var defaultBytes: Int64 { Int64(defaultGigabytes) * bytesPerGigabyte }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Int64 {
        guard defaults.object(forKey: Self.key) != nil else { return Self.defaultBytes }
        let gigabytes = Int(defaults.integer(forKey: Self.key) / Int(Self.bytesPerGigabyte))
        let clamped = min(
            max(gigabytes, Self.allowedGigabytes.lowerBound),
            Self.allowedGigabytes.upperBound)
        return Int64(clamped) * Self.bytesPerGigabyte
    }

    func save(_ bytes: Int64) {
        let gigabytes = min(
            max(Int(bytes / Self.bytesPerGigabyte), Self.allowedGigabytes.lowerBound),
            Self.allowedGigabytes.upperBound)
        defaults.set(Int64(gigabytes) * Self.bytesPerGigabyte, forKey: Self.key)
    }
}
