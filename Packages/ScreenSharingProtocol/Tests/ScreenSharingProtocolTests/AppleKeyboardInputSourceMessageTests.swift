import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleKeyboardInputSourceMessageTests: XCTestCase {
    func testBuildsNativeShareAndDisableMessagesWithoutNullTerminator() throws {
        XCTAssertEqual(
            try AppleKeyboardInputSourceMessage.share(identifier: "com.apple.keylayout.US"),
            Data([0x1a, 0x00, 0x00, 0x1a, 0x00, 0x01, 0x00, 0x16])
                + Data("com.apple.keylayout.US".utf8)
        )
        XCTAssertEqual(
            try AppleKeyboardInputSourceMessage.share(identifier: nil),
            Data([0x1a, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00])
        )
    }

    func testAcceptsMaximumIdentifierAndRejectsOneByteMore() throws {
        let maximum = String(repeating: "a", count: Int(UInt16.max) - 4)
        let maximumMessage = try AppleKeyboardInputSourceMessage.share(identifier: maximum)

        XCTAssertEqual(maximumMessage.count, 8 + maximum.utf8.count)
        XCTAssertEqual(maximumMessage.prefix(4), Data([0x1a, 0x00, 0xff, 0xff]))

        let oversized = maximum + "a"

        XCTAssertThrowsError(
            try AppleKeyboardInputSourceMessage.share(identifier: oversized)
        ) { error in
            XCTAssertEqual(error as? AppleKeyboardInputSourceError, .identifierTooLong)
        }
    }

    func testParsesRemoteInputSourceAndSecureInputFlag() {
        let payload = Data([0x00, 0x01, 0, 0, 0, 1, 0, 2, 0x55, 0x53])

        XCTAssertEqual(
            AppleKeyboardInputSourceMessage.state(from: payload),
            AppleKeyboardInputSourceState(field: 1, isSecureInput: true, identifier: "US")
        )
    }

    func testRejectsEmptyAndTruncatedRemoteIdentifiers() {
        XCTAssertNil(AppleKeyboardInputSourceMessage.state(from: Data(repeating: 0, count: 8)))
        XCTAssertNil(AppleKeyboardInputSourceMessage.state(
            from: Data([0, 1, 0, 0, 0, 0, 0, 2, 0x55])
        ))
        XCTAssertNil(AppleKeyboardInputSourceMessage.state(from: Data(repeating: 0, count: 7)))
    }
}
