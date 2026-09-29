import Foundation
import Security

/// The settings store owns migration and reference selection; this protocol
/// keeps the Keychain boundary small and makes secure-write failure handling
/// explicit without putting a test double in the production composition root.
protocol WebDAVSyncCredentialPersisting: Sendable {
    func read(reference: String) throws -> String?
    func write(_ password: String, reference: String) throws
    func remove(reference: String) throws
}

/// WebDAV credentials are intentionally isolated from forum account vaults.
/// The environment suffix prevents a local simulator credential from ever
/// being read by the production build (and vice versa).
struct KeychainWebDAVCredentialPersistence: WebDAVSyncCredentialPersisting, Sendable {
    private let service: String

    init(environment: YamiboForumEnvironment = .current) {
        switch environment {
        case .production:
            service = "com.arkalin.YamiboX.webdav.credentials"
        case .localSimulator:
            service = "com.arkalin.YamiboX.local.webdav.credentials"
        }
    }

    func read(reference: String) throws -> String? {
        var query = query(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw YamiboPersistenceError(context: "WebDAV credential is not valid UTF-8")
        }
        return password
    }

    func write(_ password: String, reference: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            // Background sync is allowed after the device has been unlocked
            // once. ThisDeviceOnly avoids syncing a WebDAV secret through
            // iCloud Keychain to another installation.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query(reference: reference) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(reference: reference).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    func remove(reference: String) throws {
        let status = SecItemDelete(query(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func query(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func keychainError(_ status: OSStatus) -> YamiboPersistenceError {
        YamiboPersistenceError(
            context: "WebDAV credential Keychain operation failed",
            underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        )
    }
}
