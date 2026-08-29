import XCTest
@testable import iScreenSharing

final class AppleRekeyTests: XCTestCase {
    func testUnwrapsKeyRotation() throws {
        let wrappingKey = Data(repeating: 0x11, count: 16)
        let contentKey = Data((0..<16).map(UInt8.init))
        let iv = Data((16..<32).map(UInt8.init))
        var payload = Data()
        payload.appendUInt32BE(7)
        payload.append(try Cryptography.encryptAESECB(contentKey, key: wrappingKey))
        payload.append(try Cryptography.encryptAESECB(iv, key: wrappingKey))

        let rekey = try AppleRekey(payload: payload)
        let keys = try rekey.unwrap(using: wrappingKey)

        XCTAssertEqual(rekey.generation, 7)
        XCTAssertEqual(keys.key, contentKey)
        XCTAssertEqual(keys.initializationVector, iv)
    }

    func testRejectsIncorrectRecordKeyLengths() {
        XCTAssertThrowsError(
            try AppleRecordKeys(
                key: Data(repeating: 0, count: 15),
                initializationVector: Data(repeating: 0, count: 16)
            )
        ) { error in
            XCTAssertEqual(error as? AppleRecordKeyError, .invalidLength)
        }
    }
}
