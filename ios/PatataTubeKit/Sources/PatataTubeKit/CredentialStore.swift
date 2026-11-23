import Foundation

public protocol CredentialStore: AnyObject {
    var baseURL: URL? { get set }
    var token: String? { get set }
    /// The server this store's data belongs to, for keying per-server state.
    /// Differs from `baseURL` only when the route switches between URLs of
    /// one server (`RoutedCredentialStore`).
    var identityURL: URL? { get }
}

public extension CredentialStore {
    var identityURL: URL? { baseURL }
}

public final class InMemoryCredentialStore: CredentialStore {
    public var baseURL: URL?
    public var token: String?
    public init(baseURL: URL? = nil, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }
}

/// The token is read on every upstream request, including while the phone is
/// locked and a video keeps playing (or downloading) in the background. The
/// Keychain default, `WhenUnlocked`, makes that read fail the moment the screen
/// locks: requests went out without `Authorization`, the server answered 401,
/// and playback stopped once the read-ahead ran dry. So the item is stored
/// `AfterFirstUnlock`, items saved before that are moved to it on the first
/// unlocked read, and the last value read is kept in memory as well.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let account = "patatatube.uploadToken"
    private let service = "patatatube"
    private let baseURLKey = "patatatube.baseURL"
    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var cachedToken: String?
    private var accessibilityMigrated = false

    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    public init() {}

    public var baseURL: URL? {
        get { defaults.string(forKey: baseURLKey).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: baseURLKey) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public var token: String? {
        get {
            lock.withLock {
                if let cachedToken { return cachedToken }
                var query = baseQuery
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                      let data = item as? Data,
                      let value = String(data: data, encoding: .utf8)
                else { return nil }
                cachedToken = value
                migrateAccessibilityIfNeeded()
                return value
            }
        }
        set {
            lock.withLock {
                SecItemDelete(baseQuery as CFDictionary)
                cachedToken = newValue
                accessibilityMigrated = true
                guard let value = newValue, let data = value.data(using: .utf8) else { return }
                var add = baseQuery
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = Self.accessibility
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    /// Items written before 2.9.1 carry the `WhenUnlocked` default. A read
    /// just succeeded, so the device is unlocked and the update can land.
    private func migrateAccessibilityIfNeeded() {
        guard !accessibilityMigrated else { return }
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecAttrAccessible as String: Self.accessibility] as CFDictionary
        )
        accessibilityMigrated = status == errSecSuccess
        DevLog.event(.state, "keychain token accessibility update", ["status": "\(status)"])
    }
}
