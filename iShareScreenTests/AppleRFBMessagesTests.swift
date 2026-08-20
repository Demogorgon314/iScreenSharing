import XCTest
@testable import iShareScreen

final class AppleRFBMessagesTests: XCTestCase {
    func testBuildsFramebufferUpdateRequest() {
        XCTAssertEqual(
            AppleRFBMessages.framebufferUpdateRequest(),
            Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff])
        )
    }

    func testViewerInfoMatchesReferenceShapeAndCommandMask() throws {
        let message = AppleRFBMessages.viewerInfo()

        XCTAssertEqual(message.count, 66)
        XCTAssertEqual(message[0], 0x21)
        XCTAssertEqual(try message.uint16BE(at: 2), 0x003e)
        XCTAssertEqual(try message.uint16BE(at: 4), 1)
        XCTAssertEqual(try message.uint32BE(at: 6), 2)
        XCTAssertEqual(message.suffix(32), AppleRFBMessages.viewerCommandMask)
    }

    func testSetEncryptionMessagesMatchCapturedBytes() {
        XCTAssertEqual(
            AppleRFBMessages.setEncryption,
            Data([0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1])
        )
        XCTAssertEqual(
            AppleRFBMessages.postEncryptionToggle,
            Data([0x12, 0, 0, 2, 0, 1, 0, 0])
        )
    }

    func testSetEncodingsPreservesSignedPseudoEncoding() throws {
        let message = try AppleRFBMessages.setEncodings()

        XCTAssertEqual(message.count, 4 + AppleRFBMessages.highPerformanceEncodings.count * 4)
        XCTAssertEqual(message.prefix(4), Data([0x02, 0x00, 0x00, 0x0d]))
        XCTAssertEqual(try message.int32BE(at: 4), 1010)
        XCTAssertEqual(try message.int32BE(at: 4 + 7 * 4), -223)
        XCTAssertEqual(try message.int32BE(at: message.count - 4), 1110)
    }
}
