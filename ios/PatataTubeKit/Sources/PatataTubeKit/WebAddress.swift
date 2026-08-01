import Foundation

/// Turns whatever the user typed in the web bridge's address bar into a URL.
///
/// There is no search-engine fallback here by design: text that is not an
/// address resolves to `nil` and the caller declines to navigate.
public enum WebAddress {
    /// - Returns: the text as a URL, prepending `https://` when it carries no
    ///   scheme, or `nil` when the result would have no host (`"cat videos"`,
    ///   `"localpage"`, empty input).
    public static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
