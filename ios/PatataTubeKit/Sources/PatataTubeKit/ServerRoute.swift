import Foundation
import Network

public enum ServerRoute: String, Equatable, Sendable {
    case lan, remote
}

/// The rules behind the LAN-first, remote-fallback choice, kept pure so they
/// can be tested without a network. Same rule as ventas-libres' `ServerPicking`.
public enum ServerRouting {
    public static let defaultLANURL = "http://192.168.1.1:3050"

    /// True when the request can't have reached the server (it failed while
    /// connecting), so sending it again through the remote URL can't duplicate
    /// anything. A timeout or a dropped connection only counts for idempotent
    /// calls: it can happen after the server started the work.
    public static func isRetryableConnectFailure(_ error: Error, idempotent: Bool) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        case .timedOut, .networkConnectionLost:
            return idempotent
        default:
            return false
        }
    }

    /// `url` rewritten from `lan` onto `remote`, keeping path and query; nil
    /// when `url` doesn't live under `lan`.
    public static func rebase(_ url: URL, from lan: URL, to remote: URL) -> URL? {
        let prefix = lan.absoluteString.hasSuffix("/") ? String(lan.absoluteString.dropLast()) : lan.absoluteString
        let target = remote.absoluteString.hasSuffix("/") ? String(remote.absoluteString.dropLast()) : remote.absoluteString
        let string = url.absoluteString
        guard string == prefix || string.hasPrefix(prefix + "/") || string.hasPrefix(prefix + "?") else {
            return nil
        }
        return URL(string: target + string.dropFirst(prefix.count))
    }

    /// scheme://host[:port] only, so logs never carry a path or a token.
    public static func redacted(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return "?" }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}

/// A `CredentialStore` whose `baseURL` is the LAN server while it answers and
/// the configured (remote) URL otherwise. Everything that builds a server URL
/// reads `baseURL` live, so this is the one seam the route switch needs.
///
/// Writes to `baseURL` set the configured remote URL; `identityURL` stays on it
/// whichever route is in use, so resume positions don't look like they belong
/// to another server when the route changes.
public final class RoutedCredentialStore: CredentialStore, @unchecked Sendable {
    private let inner: CredentialStore
    private let defaults: UserDefaults
    private let lanKey = "patatatube.lanURL"
    private let lock = NSLock()
    private var activeLAN: URL?

    public init(inner: CredentialStore, defaults: UserDefaults = .standard) {
        self.inner = inner
        self.defaults = defaults
    }

    public var baseURL: URL? {
        get { lock.withLock { activeLAN } ?? inner.baseURL }
        set { inner.baseURL = newValue }
    }

    public var token: String? {
        get { inner.token }
        set { inner.token = newValue }
    }

    public var identityURL: URL? { inner.baseURL }

    /// The configured LAN URL; an empty string turns the LAN route off.
    public var lanURLText: String {
        get { defaults.string(forKey: lanKey) ?? ServerRouting.defaultLANURL }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: lanKey) }
    }

    public var lanURL: URL? {
        let text = lanURLText
        guard !text.isEmpty, let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    public var route: ServerRoute { activeLANURL == nil ? .remote : .lan }

    func use(lan: URL?) {
        lock.withLock { activeLAN = lan }
    }

    /// The LAN URL requests are currently built on, nil while remote.
    var activeLANURL: URL? { lock.withLock { activeLAN } }

    /// A request through `failedBase` failed to connect: go remote right away.
    /// A no-op when the route already moved off it.
    func lanFailed(from failedBase: URL) {
        let wasActive = lock.withLock {
            guard activeLAN == failedBase else { return false }
            activeLAN = nil
            return true
        }
        if wasActive {
            NotificationCenter.default.post(name: .serverRouteLANFailed, object: self)
        }
    }
}

public extension Notification.Name {
    static let serverRouteLANFailed = Notification.Name("PatataTubeServerRouteLANFailed")
}

/// Probes the LAN URL (`GET /check-auth` with the token, 1s) at launch, on
/// foreground and on every network change, and points the store's `baseURL`
/// at it while it answers 200. Requiring the token's 200, not just any HTTP
/// answer, keeps some other network's 192.168.1.1 from being taken for ours.
@MainActor
public final class ServerPicker: ObservableObject {
    @Published public private(set) var route: ServerRoute = .remote
    private let store: RoutedCredentialStore
    private let monitor = NWPathMonitor()
    private var generation = 0
    private var probeTask: Task<Void, Never>?
    private var reprobeTask: Task<Void, Never>?
    private var failureObserver: NSObjectProtocol?
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public init(store: RoutedCredentialStore) {
        self.store = store
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in await self?.probe() }
        }
        monitor.start(queue: DispatchQueue(label: "patatatube.path-monitor", qos: .utility))
        failureObserver = NotificationCenter.default.addObserver(
            forName: .serverRouteLANFailed, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lanFailed() }
        }
    }

    /// Replaces any probe still in flight; only the latest one may set the route.
    public func probe() async {
        generation += 1
        let mine = generation
        probeTask?.cancel()
        let task = Task { await run(generation: mine) }
        probeTask = task
        await task.value
    }

    private func run(generation mine: Int) async {
        var answered = false
        if let lan = store.lanURL, let token = store.token, !token.isEmpty {
            var request = URLRequest(url: lan.appendingPathComponent("check-auth"), timeoutInterval: 1)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await probeSession.data(for: request) {
                answered = (response as? HTTPURLResponse)?.statusCode == 200
            }
            if Task.isCancelled { return }
        }
        guard mine == generation, !Task.isCancelled else { return }
        let lan = answered ? store.lanURL : nil
        store.use(lan: lan)
        let next: ServerRoute = lan == nil ? .remote : .lan
        if next != route {
            DevLog.event(.net, "server route -> \(next.rawValue)", [
                "route": next.rawValue,
                "base": store.baseURL.map(ServerRouting.redacted) ?? "nil",
            ])
        }
        route = next
    }

    /// The store already switched to remote; mirror it, drop any probe that
    /// may still put the LAN back, and look at the LAN again in a few seconds
    /// so a transient blip recovers.
    private func lanFailed() {
        generation += 1
        probeTask?.cancel()
        route = store.route
        DevLog.event(.net, "server route -> remote (lan failed)", ["route": "remote"])
        reprobeTask?.cancel()
        reprobeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.probe()
        }
    }

    /// Settings changed: start from the remote URL and probe the new LAN URL.
    public func settingsChanged() {
        generation += 1
        probeTask?.cancel()
        store.use(lan: nil)
        route = .remote
        Task { await probe() }
    }
}
