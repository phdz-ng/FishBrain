import Foundation
import Security

/// Where API keys are kept. Only the Keychain, in the real app.
protocol SecretStore: Sendable {
    func secret(for provider: AIProvider) -> String?
    func setSecret(_ secret: String, for provider: AIProvider) throws
    func removeSecret(for provider: AIProvider) throws
}

enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keys in the macOS Keychain, one generic password per provider (service `com.fishbrain.ai.<provider>`).
/// They are never written anywhere else: not settings, not `decks.json`, not a log.
struct KeychainSecretStore: SecretStore {
    /// Which Keychain entry is whose.
    static let account = "api-key"

    /// Tests use their own prefix so they never touch a real key.
    var servicePrefix: String?

    init(servicePrefix: String? = nil) {
        self.servicePrefix = servicePrefix
    }

    private func service(for provider: AIProvider) -> String {
        servicePrefix.map { "\($0).\(provider.rawValue.lowercased())" } ?? provider.keychainService
    }

    private func query(for provider: AIProvider) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(for: provider),
            kSecAttrAccount: Self.account,
        ]
    }

    func secret(for provider: AIProvider) -> String? {
        var query = query(for: provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String, for provider: AIProvider) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(for: provider) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var add = query(for: provider)
        add[kSecValueData] = data
        // Only this Mac, and only once it has been unlocked; never synced to iCloud Keychain.
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func removeSecret(for provider: AIProvider) throws {
        let status = SecItemDelete(query(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// Keys in memory only: sample-data mode and previews, which must never touch the real Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [AIProvider: String] = [:]

    func secret(for provider: AIProvider) -> String? {
        lock.withLock { secrets[provider] }
    }

    func setSecret(_ secret: String, for provider: AIProvider) throws {
        lock.withLock { secrets[provider] = secret }
    }

    func removeSecret(for provider: AIProvider) throws {
        lock.withLock { _ = secrets.removeValue(forKey: provider) }
    }
}
