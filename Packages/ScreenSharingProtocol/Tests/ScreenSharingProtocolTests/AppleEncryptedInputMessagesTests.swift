import XCTest
@testable import ScreenSharingProtocol

final class AppleEncryptedInputMessagesTests: XCTestCase {
    func testBuildsCapturedPointerCiphertext() throws {
        let recordLayer = try makeRecordLayer()

        let message = try recordLayer.encryptPointerEvent(
            buttons: 3,
            x: 0x1234,
            y: 0x5678,
            clickCount: 2
        )

        XCTAssertEqual(
            message,
            Data([
                0x10, 0x05, 0xe9, 0x3e, 0x9b, 0xe4, 0x74, 0xb5, 0xae,
                0x84, 0xd2, 0x92, 0x49, 0xa6, 0xf6, 0x8f, 0xfd, 0x77,
            ])
        )
    }

    func testBuildsCapturedKeyboardCiphertext() throws {
        let recordLayer = try makeRecordLayer()

        let message = try recordLayer.encryptKeyEvent(
            isDown: true,
            keySymbol: 0xff51,
            timestampDelta: 0x0102_0304,
            keyboardType: 40,
            keyCode: 123
        )

        XCTAssertEqual(
            message,
            Data([
                0x10, 0x01, 0x6c, 0x86, 0x03, 0x33, 0x2f, 0x14, 0xaa,
                0x81, 0x0f, 0x5b, 0x8c, 0x8f, 0x46, 0xe4, 0xa3, 0x73,
            ])
        )
    }

    func testInputEncryptionDoesNotAdvanceOrderedRecordState() throws {
        let recordLayer = try makeRecordLayer()
        let untouchedRecordLayer = try makeRecordLayer()

        _ = try recordLayer.encryptPointerEvent(buttons: 1, x: 2, y: 3)

        XCTAssertEqual(
            try recordLayer.encrypt(Data([0xaa, 0xbb])),
            try untouchedRecordLayer.encrypt(Data([0xaa, 0xbb]))
        )
    }

    private func makeRecordLayer() throws -> AppleEncryptedRecordLayer {
        try AppleEncryptedRecordLayer(keys: AppleRecordKeys(
            key: Data(repeating: 0, count: 16),
            initializationVector: Data(repeating: 0, count: 16)
        ))
    }
}
