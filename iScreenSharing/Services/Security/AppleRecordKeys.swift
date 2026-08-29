import Foundation
import ScreenSharingProtocol

extension AppleRekey {
    func unwrap(using key: Data) throws -> AppleRecordKeys {
        try AppleRecordKeys(
            key: try Cryptography.decryptAESECB(encryptedKey, key: key),
            initializationVector: try Cryptography.decryptAESECB(encryptedIV, key: key)
        )
    }
}

struct AppleRecordKeys: Equatable, Sendable {
    let key: Data
    let initializationVector: Data

    init(key: Data, initializationVector: Data) throws {
        guard key.count == 16, initializationVector.count == 16 else {
            throw AppleRecordKeyError.invalidLength
        }
        self.key = key
        self.initializationVector = initializationVector
    }
}

enum AppleRecordKeyError: LocalizedError, Equatable {
    case invalidLength

    var errorDescription: String? {
        "The Mac returned invalid encryption key material."
    }
}
