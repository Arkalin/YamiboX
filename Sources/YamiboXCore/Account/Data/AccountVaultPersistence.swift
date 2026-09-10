import Foundation
import Security

protocol AccountVaultPersisting: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct KeychainAccountVaultPersistence: AccountVaultPersisting {
    var service = "com.arkalin.YamiboX.accounts"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "vault",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AccountSwitchError.secureStorage(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccountSwitchError.secureStorage(status) }
    }
}

/// Ephemeral login attempts must never reach preferences or Keychain.
final class MemoryAccountVaultPersistence: AccountVaultPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
}
