import Foundation

/// Reads what `./deploy --devlog` baked into Info.plist. The URL comes in as an
/// xcodebuild command-line setting (an xcconfig would read the `//` as a
/// comment); every other build leaves it empty, so there is no server to send to.
public enum DevLogEndpoint {
    public static let urlInfoKey = "PatataTubeDevLogURL"

    public static func url(infoDictionary: [String: Any]?) -> URL? {
        guard let raw = infoDictionary?[urlInfoKey] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// "2.7.29 (211)", stamped on every record so a log says which build wrote it.
    public static func build(infoDictionary: [String: Any]?) -> String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let number = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }
}
