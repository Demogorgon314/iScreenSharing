import Foundation
import XCTest
import ScreenSharingProtocol

final class StandardRFBMessagesTests: XCTestCase {
    func testBuildsClientInitializationAndStandardPixelFormat() {
        XCTAssertEqual(StandardRFBMessages.clientInit, Data([1]))
        XCTAssertEqual(
            StandardRFBMessages.setPixelFormat(.standard),
            Data([
                0, 0, 0, 0,
                32, 24, 0, 1,
                0, 255, 0, 255, 0, 255,
                16, 8, 0, 0, 0, 0,
            ])
        )
    }

    func testBuildsOrderedEncodingList() throws {
        XCTAssertEqual(
            try StandardRFBMessages.setEncodings([
                StandardRFBMessages.subZlibThousandsEncoding,
                StandardRFBMessages.copyRectangleEncoding,
                StandardRFBMessages.zlibEncoding,
                StandardRFBMessages.rawEncoding,
                StandardRFBMessages.hextileEncoding,
                StandardRFBMessages.desktopSizeEncoding,
            ]),
            Data([
                2, 0, 0, 6,
                0, 0, 3, 0xea,
                0, 0, 0, 1,
                0, 0, 0, 6,
                0, 0, 0, 0,
                0, 0, 0, 5,
                0xff, 0xff, 0xff, 0x21,
            ])
        )
    }

    func testBuildsStandardInputMessages() {
        XCTAssertEqual(
            StandardRFBMessages.keyEvent(isDown: true, symbol: 0x41),
            Data([4, 1, 0, 0, 0, 0, 0, 0x41])
        )
        XCTAssertEqual(
            StandardRFBMessages.pointerEvent(buttons: 5, x: 0x1234, y: 0x5678),
            Data([5, 5, 0x12, 0x34, 0x56, 0x78])
        )
    }

    func testRejectsOversizedEncodingList() {
        XCTAssertThrowsError(
            try StandardRFBMessages.setEncodings(
                Array(repeating: StandardRFBMessages.rawEncoding, count: 65_536)
            )
        ) { error in
            XCTAssertEqual(error as? StandardRFBMessageError, .tooManyEncodings)
        }
    }
}
