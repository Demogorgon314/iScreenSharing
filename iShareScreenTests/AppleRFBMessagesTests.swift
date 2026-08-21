import XCTest
@testable import iShareScreen

final class AppleRFBMessagesTests: XCTestCase {
    func testBuildsFramebufferUpdateRequest() {
        XCTAssertEqual(
            AppleRFBMessages.framebufferUpdateRequest(),
            Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff])
        )
    }

    func testBuildsAutoFramebufferUpdateForCombinedCanvas() {
        XCTAssertEqual(
            AppleRFBMessages.autoFramebufferUpdate(width: 3840, height: 1080),
            Data([
                0x09, 0x00, 0x00, 0x01,
                0xff, 0xff, 0xff, 0xff,
                0x00, 0x00, 0x00, 0x00,
                0x0f, 0x00, 0x04, 0x38,
            ])
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

    func testBuildsKeyEventWithX11KeySymbol() {
        XCTAssertEqual(
            AppleRFBMessages.keyEvent(isDown: true, keySymbol: 0xff51),
            Data([0x04, 0x01, 0, 0, 0, 0, 0xff, 0x51])
        )
    }

    func testBuildsObserveAndControlModeMessages() {
        XCTAssertEqual(AppleRFBMessages.controlMode(observing: true), Data([0x0a, 0, 0, 0]))
        XCTAssertEqual(AppleRFBMessages.controlMode(observing: false), Data([0x0a, 0, 0, 1]))
    }

    func testSelectsCombinedDisplayAggregate() {
        XCTAssertEqual(
            AppleRFBMessages.selectCombinedDisplays,
            Data([0x0d, 0x01, 0, 0, 0, 0, 0, 0])
        )
    }

    func testSelectsIndividualDisplay() {
        XCTAssertEqual(
            AppleRFBMessages.selectDisplay(0x1234_5678),
            Data([0x0d, 0x00, 0, 0, 0x12, 0x34, 0x56, 0x78])
        )
    }

    func testBuildsAppleEncryptedPointerEvent() throws {
        let message = try AppleRFBMessages.encryptedPointerEvent(
            buttons: 3,
            x: 0x1234,
            y: 0x5678,
            contentKey: Data(repeating: 0, count: 16)
        )
        XCTAssertEqual(
            message,
            Data([
                0x10, 0x00, 0xe9, 0x3e, 0x9b, 0xe4, 0x74, 0xb5, 0xae,
                0x84, 0xd2, 0x92, 0x49, 0xa6, 0xf6, 0x8f, 0xfd, 0x77,
            ])
        )
    }
}
