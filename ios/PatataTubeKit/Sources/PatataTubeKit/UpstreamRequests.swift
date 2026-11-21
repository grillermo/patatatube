import Foundation

/// Builds upstream requests from the credentials as they are **now**, so a
/// retry follows a LAN↔remote route switch and a refreshed token.
///
/// `@unchecked Sendable`: `CredentialStore` is a non-Sendable class protocol
/// that the old proxy also read from background threads; reads only.
struct UpstreamRequests: @unchecked Sendable {
    /// The URL as the caller built it.
    let url: URL
    /// When set, every request moves `url` onto this store's current base URL
    /// and uses its current token.
    let credentials: CredentialStore?
    let fallbackToken: String?

    init(url: URL, credentials: CredentialStore?, fallbackToken: String? = nil) {
        self.url = url
        self.credentials = credentials
        self.fallbackToken = fallbackToken
    }

    func ranged(_ range: DownloadByteRange) -> URLRequest {
        var request = URLRequest(url: currentURL())
        if let token = credentials?.token ?? fallbackToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        return request
    }

    func probe() -> URLRequest {
        ranged(DownloadByteRange(start: 0, end: 0))
    }

    func currentURL() -> URL {
        guard let base = credentials?.baseURL else { return url }
        return Self.rebase(url, onto: base)
    }

    /// Swaps scheme, host and port. Assumes both bases share their path
    /// prefix, which holds for the LAN and remote URLs (both are bare hosts).
    static func rebase(_ url: URL, onto base: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = target.scheme
        components.host = target.host
        components.port = target.port
        return components.url ?? url
    }
}
