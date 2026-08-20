import Foundation

enum AppleRSA1 {
    static let credentialFieldLength = 64
    static let publicKeyRequest = Data([
        0x21,
        0x00, 0x00, 0x00, 0x0a,
        0x01, 0x00,
        0x52, 0x53, 0x41, 0x31,
        0x00, 0x00,
        0x00, 0x00,
    ])

    static func parsePublicKeyResponse(_ packet: Data) throws -> Data {
        guard packet.count >= 6 else {
            throw AppleRSA1Error.invalidPublicKeyResponse
        }
        let keyLength = try Int(packet.uint32BE(at: 2))
        guard keyLength > 0, keyLength <= packet.count - 6 else {
            throw AppleRSA1Error.invalidPublicKeyResponse
        }
        return packet.subdata(in: 6..<(6 + keyLength))
    }

    static func credentialPlaintext(
        username: String,
        password: String,
        randomBytes: (Int) throws -> Data
    ) throws -> Data {
        let usernameField = try credentialField(username, randomBytes: randomBytes)
        let passwordField = try credentialField(password, randomBytes: randomBytes)
        return usernameField + passwordField
    }

    static func authenticationRequest(
        encryptedCredentials: Data,
        encryptedAESKey: Data
    ) throws -> Data {
        guard encryptedCredentials.count == credentialFieldLength * 2,
              encryptedAESKey.count == 256 else {
            throw AppleRSA1Error.invalidEncryptedPayload
        }

        var body = Data([0x01, 0x00])
        body.append(contentsOf: [0x52, 0x53, 0x41, 0x31])
        body.append(contentsOf: [0x00, 0x01])
        body.append(encryptedCredentials)
        body.append(contentsOf: [0x00, 0x01])
        body.append(encryptedAESKey)

        var framed = Data()
        framed.appendUInt32BE(UInt32(body.count))
        framed.append(body)
        return framed
    }

    static func parseSecurityResult(_ data: Data) throws {
        guard data.count == 4 else {
            throw AppleRSA1Error.invalidSecurityResult
        }
        let result = try data.uint32BE(at: 0)
        guard result == 0 else {
            throw AppleRSA1Error.authenticationRejected(result)
        }
    }

    private static func credentialField(
        _ value: String,
        randomBytes: (Int) throws -> Data
    ) throws -> Data {
        let encoded = Data(value.utf8)
        guard encoded.count < credentialFieldLength else {
            throw AppleRSA1Error.credentialTooLong
        }
        var field = encoded
        field.append(0)
        let paddingLength = credentialFieldLength - field.count
        let padding = try randomBytes(paddingLength)
        guard padding.count == paddingLength else {
            throw AppleRSA1Error.invalidRandomPadding
        }
        field.append(padding)
        return field
    }
}

enum AppleRSA1Error: LocalizedError, Equatable {
    case invalidPublicKeyResponse
    case credentialTooLong
    case invalidRandomPadding
    case invalidEncryptedPayload
    case invalidSecurityResult
    case authenticationRejected(UInt32)
    case unsupportedServer

    var errorDescription: String? {
        switch self {
        case .invalidPublicKeyResponse:
            "The Mac returned an invalid RSA public key."
        case .credentialTooLong:
            "The account name or password is too long."
        case .invalidRandomPadding, .invalidEncryptedPayload:
            "Couldn’t prepare the encrypted credentials."
        case .invalidSecurityResult:
            "The Mac returned an invalid authentication result."
        case .authenticationRejected:
            "The account name or password was not accepted."
        case .unsupportedServer:
            "This Mac doesn’t offer the supported Apple RSA authentication method."
        }
    }
}

