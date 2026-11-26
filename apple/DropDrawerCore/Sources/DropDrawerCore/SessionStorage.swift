import Foundation
import Security

/// Persists session credentials in Keychain and preferences in UserDefaults
/// (optionally backed by an App Group suite so a Share Extension can read them).
public final class SessionStorage: @unchecked Sendable {
    public static let appGroupId = "group.com.dropdrawer.shared"

    private let defaults: UserDefaults
    private let keychainService: String

    private enum Keys {
        static let serverUrl = "dd.server_url"
        static let userId = "dd.user_id"
        static let username = "dd.username"
        static let deviceId = "dd.device_id"
        static let dropPolicy = "dd.drop_policy"
        static let autoCloudThresholdMb = "dd.auto_cloud_threshold_mb"
        static let defaultTtlHours = "dd.default_ttl_hours"
        static let localFilePaths = "dd.local_file_paths"
        static let tokenAccount = "auth_jwt_token"
        static let unsignedSimTokenFallback = "dd.unsigned_sim_token"
    }

    public init(
        suiteName: String? = nil,
        keychainService: String = "com.dropdrawer.ios.session"
    ) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
            Self.migrateStandardDefaultsIfNeeded(into: suite)
        } else {
            self.defaults = .standard
        }
        self.keychainService = keychainService
    }

    /// Preserves existing login/settings when migrating from `.standard` to an App Group suite.
    private static func migrateStandardDefaultsIfNeeded(into suite: UserDefaults) {
        let standard = UserDefaults.standard
        guard suite.string(forKey: Keys.userId) == nil,
              standard.string(forKey: Keys.userId) != nil
        else { return }
        let keysToMigrate = [
            Keys.serverUrl,
            Keys.userId,
            Keys.username,
            Keys.deviceId,
            Keys.dropPolicy,
            Keys.autoCloudThresholdMb,
            Keys.defaultTtlHours,
            Keys.localFilePaths,
            Keys.unsignedSimTokenFallback,
        ]
        for key in keysToMigrate {
            if let value = standard.object(forKey: key), suite.object(forKey: key) == nil {
                suite.set(value, forKey: key)
            }
        }
    }

    public var serverUrl: String {
        get { defaults.string(forKey: Keys.serverUrl) ?? "http://127.0.0.1:8080" }
        set { defaults.set(newValue, forKey: Keys.serverUrl) }
    }

    public var user: UserProfile? {
        get {
            guard let id = defaults.string(forKey: Keys.userId),
                  let username = defaults.string(forKey: Keys.username)
            else { return nil }
            return UserProfile(id: id, username: username)
        }
        set {
            if let newValue {
                defaults.set(newValue.id, forKey: Keys.userId)
                defaults.set(newValue.username, forKey: Keys.username)
            } else {
                defaults.removeObject(forKey: Keys.userId)
                defaults.removeObject(forKey: Keys.username)
            }
        }
    }

    public var deviceId: String? {
        get { defaults.string(forKey: Keys.deviceId) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.deviceId)
            } else {
                defaults.removeObject(forKey: Keys.deviceId)
            }
        }
    }

    public var dropPolicy: DropPolicy {
        get {
            DropPolicy(rawValue: defaults.string(forKey: Keys.dropPolicy) ?? "") ?? .smart
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.dropPolicy) }
    }

    public var autoCloudThresholdMb: Int {
        get {
            let v = defaults.integer(forKey: Keys.autoCloudThresholdMb)
            return v > 0 ? v : 20
        }
        set { defaults.set(newValue, forKey: Keys.autoCloudThresholdMb) }
    }

    public var defaultTtlHours: Int {
        get { defaults.integer(forKey: Keys.defaultTtlHours) }
        set { defaults.set(newValue, forKey: Keys.defaultTtlHours) }
    }

    public var localFilePaths: [String: String] {
        get { defaults.dictionary(forKey: Keys.localFilePaths) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.localFilePaths) }
    }

    public var token: String? {
        get { readKeychain(account: Keys.tokenAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                saveKeychain(value: newValue, account: Keys.tokenAccount)
            } else {
                deleteKeychain(account: Keys.tokenAccount)
            }
        }
    }

    public func clearSession() {
        token = nil
        user = nil
        deviceId = nil
        localFilePaths = [:]
    }

    private func saveKeychain(value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess {
            defaults.removeObject(forKey: Keys.unsignedSimTokenFallback)
        }
        #if targetEnvironment(simulator) || os(macOS)
        if status == errSecMissingEntitlement {
            // Unsigned iOS Simulator / macOS unit-test builds lack keychain entitlements (-34018).
            defaults.set(value, forKey: Keys.unsignedSimTokenFallback)
        }
        #endif
    }

    private func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        #if targetEnvironment(simulator) || os(macOS)
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            return defaults.string(forKey: Keys.unsignedSimTokenFallback)
        }
        #endif
        return nil
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: Keys.unsignedSimTokenFallback)
    }
}
