import Foundation

struct AppleRekey: Equatable, Sendable {
    static let encoding: Int32 = 1103
    static let payloadLength = 36

    let generation: UInt32
    let encryptedKey: Data
    let encryptedIV: Data

    init(payload: Data) throws {
        guard payload.count == Self.payloadLength else {
            throw AppleRekeyError.invalidPayload
        }
        generation = try payload.uint32BE(at: 0)
        encryptedKey = payload.subdata(in: 4..<20)
        encryptedIV = payload.subdata(in: 20..<36)
    }

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
            throw AppleRekeyError.invalidPayload
        }
        self.key = key
        self.initializationVector = initializationVector
    }
}

enum AppleRekeyError: LocalizedError, Equatable {
    case invalidPayload
    case unsupportedFramebufferMessage(UInt8)
    case unsupportedEncoding(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "The Mac returned an invalid encryption key update."
        case .unsupportedFramebufferMessage:
            "The Mac returned an unexpected message before encryption was enabled."
        case .unsupportedEncoding:
            "The Mac returned an unsupported setup encoding."
        }
    }
}
