import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleRSA1Tests: XCTestCase {
    func testPublicKeyRequestMatchesReferenceProtocol() {
        XCTAssertEqual(
            AppleRSA1.publicKeyRequest,
            Data([0x21, 0, 0, 0, 10, 1, 0, 0x52, 0x53, 0x41, 0x31, 0, 0, 0, 0])
        )
    }

    func testParsesLengthDelimitedPublicKeyWithoutIncludingTrailingBytes() throws {
        let packet = Data([0x01, 0x00, 0, 0, 0, 4, 0xde, 0xad, 0xbe, 0xef, 0])

        XCTAssertEqual(
            try AppleRSA1.parsePublicKeyResponse(packet),
            Data([0xde, 0xad, 0xbe, 0xef])
        )
    }

    func testRejectsInvalidPublicKeyLengths() {
        let packets = [
            Data([0x01, 0x00, 0, 0, 0, 0]),
            Data([0x01, 0x00, 0, 0, 0, 4, 0xde, 0xad]),
            Data([0x01, 0x00, 0, 0, 0]),
        ]

        for packet in packets {
            XCTAssertThrowsError(try AppleRSA1.parsePublicKeyResponse(packet)) { error in
                XCTAssertEqual(error as? AppleRSA1Error, .invalidPublicKeyResponse)
            }
        }
    }

    func testCredentialPlaintextUsesNullTerminatedRandomPaddedFields() throws {
        let plaintext = try AppleRSA1.credentialPlaintext(
            username: "deepdream",
            password: "secret",
            randomBytes: { Data(repeating: 0xa5, count: $0) }
        )

        XCTAssertEqual(plaintext.count, 128)
        XCTAssertEqual(plaintext.prefix(10), Data("deepdream\0".utf8))
        XCTAssertEqual(plaintext[10], 0xa5)
        XCTAssertEqual(plaintext[64..<71], Data("secret\0".utf8))
        XCTAssertEqual(plaintext[71], 0xa5)
    }

    func testCredentialPlaintextRejectsOversizedUTF8AndWrongPaddingLength() {
        XCTAssertThrowsError(
            try AppleRSA1.credentialPlaintext(
                username: String(repeating: "é", count: 32),
                password: "secret",
                randomBytes: { Data(repeating: 0, count: $0) }
            )
        ) { error in
            XCTAssertEqual(error as? AppleRSA1Error, .credentialTooLong)
        }

        XCTAssertThrowsError(
            try AppleRSA1.credentialPlaintext(
                username: "user",
                password: "secret",
                randomBytes: { Data(repeating: 0, count: max(0, $0 - 1)) }
            )
        ) { error in
            XCTAssertEqual(error as? AppleRSA1Error, .invalidRandomPadding)
        }
    }

    func testAuthenticationRequestMatchesRSA1EnvelopeShape() throws {
        let request = try AppleRSA1.authenticationRequest(
            encryptedCredentials: Data(repeating: 0x11, count: 128),
            encryptedAESKey: Data(repeating: 0x22, count: 256)
        )

        XCTAssertEqual(request.prefix(4), Data([0, 0, 1, 0x8a]))
        XCTAssertEqual(request[4..<12], Data([1, 0, 0x52, 0x53, 0x41, 0x31, 0, 1]))
        XCTAssertEqual(request[140..<142], Data([0, 1]))
        XCTAssertEqual(request.count, 398)
    }

    func testAuthenticationRequestRejectsInvalidPayloadLengths() {
        XCTAssertThrowsError(
            try AppleRSA1.authenticationRequest(
                encryptedCredentials: Data(repeating: 0, count: 127),
                encryptedAESKey: Data(repeating: 0, count: 256)
            )
        ) { error in
            XCTAssertEqual(error as? AppleRSA1Error, .invalidEncryptedPayload)
        }
    }

    func testSecurityResultAcceptsZeroAndClassifiesMalformedAndRejectedResults() throws {
        try AppleRSA1.parseSecurityResult(Data(repeating: 0, count: 4))

        XCTAssertThrowsError(try AppleRSA1.parseSecurityResult(Data([0, 0, 0]))) { error in
            XCTAssertEqual(error as? AppleRSA1Error, .invalidSecurityResult)
        }
        XCTAssertThrowsError(try AppleRSA1.parseSecurityResult(Data([0, 0, 0, 1]))) { error in
            XCTAssertEqual(error as? AppleRSA1Error, .authenticationRejected(1))
        }
    }
}
