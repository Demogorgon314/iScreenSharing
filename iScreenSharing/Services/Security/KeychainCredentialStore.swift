import Foundation
import Security

protocol CredentialStoring: Sendable {
    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials?
    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws
    func delete(for endpoint: ConnectionEndpoint) throws
}

struct KeychainCredentialStore: CredentialStoring {
    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials? {
        var query = baseQuery(for: endpoint)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let result = item as? [String: Any],
              let username = result[kSecAttrAccount as String] as? String,
              let passwordData = result[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw KeychainCredentialError.operationFailed(status)
        }
        return try ScreenSharingCredentials(username: username, password: password)
    }

    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws {
        try delete(for: endpoint)
        var item = baseQuery(for: endpoint)
        item[kSecAttrAccount as String] = credentials.username
        item[kSecAttrLabel as String] = "Screen Sharing — \(endpoint.displayName)"
        item[kSecValueData as String] = Data(credentials.password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainCredentialError.operationFailed(status)
        }
    }

    func delete(for endpoint: ConnectionEndpoint) throws {
        let status = SecItemDelete(baseQuery(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.operationFailed(status)
        }
    }

    private func baseQuery(for endpoint: ConnectionEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.wangkai.iShareScreen.\(endpoint.url.absoluteString)",
        ]
    }
}

enum KeychainCredentialError: LocalizedError {
    case operationFailed(OSStatus)

    var errorDescription: String? {
        "Couldn’t access the saved Screen Sharing password in Keychain."
    }
}

