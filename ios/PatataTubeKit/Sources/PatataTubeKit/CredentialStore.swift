import Foundation

public protocol CredentialStore: AnyObject {
    var baseURL: URL? { get set }
    var token: String? { get set }
}

public final class InMemoryCredentialStore: CredentialStore {
    public var baseURL: URL?
    public var token: String?
    public init(baseURL: URL? = nil, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }
}

public final class KeychainCredentialStore: CredentialStore {
    private let account = "patatatube.uploadToken"
    private let service = "patatatube"
    private let baseURLKey = "patatatube.baseURL"
    private let defaults = UserDefaults.standard

    public init() {}

    public var baseURL: URL? {
        get { defaults.string(forKey: baseURLKey).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: baseURLKey) }
    }

    public var token: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue, let data = value.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
