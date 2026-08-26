import Foundation
import Security

protocol TailscaleStateKeyStoring: Sendable {
    func loadOrCreateKey() throws -> Data
}

struct KeychainTailscaleStateKeyStore: TailscaleStateKeyStoring {
    private static let service = "com.wangkai.iShareScreen.tailscale-state"
    private static let account = "state-encryption-key"
    private static let keyLength = 32

    func loadOrCreateKey() throws -> Data {
        if let existing = try loadKey() {
            guard existing.count == Self.keyLength else {
                throw TailscaleStateKeyError.invalidStoredKey
            }
            return existing
        }

        var key = Data(count: Self.keyLength)
        let randomStatus = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, Self.keyLength, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw TailscaleStateKeyError.operationFailed(randomStatus)
        }

        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try loadKey() {
            guard existing.count == Self.keyLength else {
                throw TailscaleStateKeyError.invalidStoredKey
            }
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw TailscaleStateKeyError.operationFailed(addStatus)
        }
        return key
    }

    private func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TailscaleStateKeyError.operationFailed(status)
        }
        return data
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

enum TailscaleStateKeyError: LocalizedError {
    case invalidStoredKey
    case operationFailed(OSStatus)

    var errorDescription: String? {
        "Couldn’t securely access the embedded Tailscale state."
    }
}
