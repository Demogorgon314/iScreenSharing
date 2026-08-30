import Foundation

/// Apple RSA1 authentication messages used by high-performance Screen Sharing.
public enum AppleRSA1 {
    public static let credentialFieldLength = 64
    public static let publicKeyRequest = Data([
        0x21,
        0x00, 0x00, 0x00, 0x0a,
        0x01, 0x00,
        0x52, 0x53, 0x41, 0x31,
        0x00, 0x00,
        0x00, 0x00,
    ])

    public static func parsePublicKeyResponse(_ packet: Data) throws -> Data {
        guard packet.count >= 6,
              let rawKeyLength = BigEndianWire.uint32(from: packet, at: 2),
              let keyLength = Int(exactly: rawKeyLength),
              keyLength > 0,
              keyLength <= packet.count - 6 else {
            throw AppleRSA1Error.invalidPublicKeyResponse
        }
        return packet.subdata(in: 6..<(6 + keyLength))
    }

    public static func credentialPlaintext(
        username: String,
        password: String,
        randomBytes: (Int) throws -> Data
    ) throws -> Data {
        let usernameField = try credentialField(username, randomBytes: randomBytes)
        let passwordField = try credentialField(password, randomBytes: randomBytes)
        return usernameField + passwordField
    }

    public static func authenticationRequest(
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
        BigEndianWire.append(UInt32(body.count), to: &framed)
        framed.append(body)
        return framed
    }

    public static func parseSecurityResult(_ data: Data) throws {
        guard data.count == 4,
              let result = BigEndianWire.uint32(from: data, at: 0) else {
            throw AppleRSA1Error.invalidSecurityResult
        }
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

public enum AppleRSA1Error: LocalizedError, Equatable {
    case invalidPublicKeyResponse
    case credentialTooLong
    case invalidRandomPadding
    case invalidEncryptedPayload
    case invalidSecurityResult
    case authenticationRejected(UInt32)

    public var errorDescription: String? {
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
        }
    }
}
