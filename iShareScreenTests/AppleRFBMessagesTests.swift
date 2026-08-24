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
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x0f, 0x00, 0x04, 0x38,
            ])
        )
    }

    func testBuildsDisabledAutoFramebufferUpdateWithNativePauseSentinel() {
        XCTAssertEqual(
            AppleRFBMessages.autoFramebufferUpdate(intervalMilliseconds: .max),
            Data([
                0x09, 0x00, 0x00, 0x01,
                0xff, 0xff, 0xff, 0xff,
                0x00, 0x00, 0x00, 0x00,
                0xff, 0xff, 0xff, 0xff,
            ])
        )
    }

    func testViewerInfoMatchesNativeViewerCapture() {
        XCTAssertEqual(
            AppleRFBMessages.viewerInfo(),
            Data([
                0x21, 0x00, 0x00, 0x3e, 0x00, 0x01,
                0x00, 0x00, 0x00, 0x02,
                0x00, 0x00, 0x00, 0x05,
                0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x0f,
                0x00, 0x00, 0x00, 0x07,
                0x00, 0x00, 0x00, 0x07,
                0xb0, 0x00, 0x08, 0x03, 0x90, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ])
        )
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
        XCTAssertEqual(message.prefix(4), Data([0x02, 0x00, 0x00, 0x0b]))
        XCTAssertEqual(try message.int32BE(at: 4), 1010)
        XCTAssertEqual(try message.int32BE(at: 4 + 5 * 4), -223)
        XCTAssertEqual(try message.int32BE(at: message.count - 4), 1110)
        XCTAssertFalse(AppleRFBMessages.highPerformanceEncodings.contains(6))
        XCTAssertFalse(AppleRFBMessages.highPerformanceEncodings.contains(16))
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
            clickCount: 2,
            contentKey: Data(repeating: 0, count: 16)
        )
        XCTAssertEqual(
            message,
            Data([
                0x10, 0x05, 0xe9, 0x3e, 0x9b, 0xe4, 0x74, 0xb5, 0xae,
                0x84, 0xd2, 0x92, 0x49, 0xa6, 0xf6, 0x8f, 0xfd, 0x77,
            ])
        )
    }


    func testEncryptedPointerMovementUsesVersionOneFlag() throws {
        let key = Data(repeating: 0, count: 16)
        let message = try AppleRFBMessages.encryptedPointerEvent(
            buttons: 0,
            x: 1,
            y: 2,
            timestampDelta: 0x0102_0304,
            contentKey: key
        )

        XCTAssertEqual(message[1], 1)
        XCTAssertEqual(
            try Cryptography.decryptAESECB(message.dropFirst(2), key: key),
            Data([0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0xff, 0, 0, 1, 0, 2])
        )
    }

    func testBuildsEncryptedKeyboardEventWithNativeFields() throws {
        let key = Data(repeating: 0, count: 16)
        let message = try AppleRFBMessages.encryptedKeyEvent(
            isDown: true,
            keySymbol: 0xff51,
            timestampDelta: 0x0102_0304,
            keyboardType: 40,
            keyCode: 123,
            contentKey: key
        )

        XCTAssertEqual(message.prefix(2), Data([0x10, 0x01]))
        XCTAssertEqual(
            try Cryptography.decryptAESECB(message.dropFirst(2), key: key),
            Data([0xff, 1, 0, 0, 0xff, 0x51, 1, 2, 3, 4, 0, 0, 0, 40, 0, 123])
        )
    }

    func testKeyboardEventUsesSharedInputSourceSubtype() throws {
        let message = try AppleRFBMessages.encryptedKeyEvent(
            isDown: true,
            keySymbol: 0x71,
            timestampDelta: 0,
            keyboardType: 40,
            keyCode: 12,
            subtype: 3,
            contentKey: Data(repeating: 0, count: 16)
        )

        XCTAssertEqual(message.prefix(2), Data([0x10, 0x03]))
    }

    func testBuildsNativeHighPrecisionScrollWheelEvent() {
        let event = AppleScrollWheelEvent(
            deltaX: -1,
            deltaY: 2,
            deltaZ: -3,
            fixedDeltaX: 0x0102_0304,
            fixedDeltaY: -2,
            fixedDeltaZ: 0,
            pointDeltaX: 0x1122_3344,
            pointDeltaY: -1,
            pointDeltaZ: 4,
            scrollPhase: 1,
            momentumPhase: 2,
            scrollCount: 3,
            flags: 0x1234_5678
        )

        XCTAssertEqual(
            AppleRFBMessages.scrollWheelEvent(event, x: 0x9abc, y: 0xdef0),
            Data([
                0x17, 0x00, 0x00, 0x36, 0x00, 0x01, 0x00, 0x0b,
                0xff, 0xff, 0x00, 0x02, 0xff, 0xfd,
                0x01, 0x02, 0x03, 0x04, 0xff, 0xff, 0xff, 0xfe,
                0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44,
                0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x04,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
                0x00, 0x00, 0x00, 0x03, 0x12, 0x34, 0x56, 0x78,
                0x9a, 0xbc, 0xde, 0xf0,
            ])
        )
    }
}
