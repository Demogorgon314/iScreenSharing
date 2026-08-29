import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleRekeyTests: XCTestCase {
    func testParsesNativeKeyUpdatePayload() throws {
        var payload = Data([0x00, 0x00, 0x00, 0x07])
        payload.append(contentsOf: 0x00...0x0f)
        payload.append(contentsOf: 0x10...0x1f)

        let rekey = try AppleRekey(payload: payload)

        XCTAssertEqual(AppleRekey.encoding, 1103)
        XCTAssertEqual(AppleRekey.payloadLength, 36)
        XCTAssertEqual(rekey.generation, 7)
        XCTAssertEqual(rekey.encryptedKey, Data(0x00...0x0f))
        XCTAssertEqual(rekey.encryptedIV, Data(0x10...0x1f))
    }

    func testRejectsTruncatedAndOversizedPayloads() {
        for length in [0, 35, 37] {
            XCTAssertThrowsError(
                try AppleRekey(payload: Data(repeating: 0, count: length))
            ) { error in
                XCTAssertEqual(error as? AppleRekeyError, .invalidPayload)
            }
        }
    }
}
