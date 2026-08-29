import Foundation

enum AppleEncryptedInputMessages {
    static func pointerEvent(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        clickCount: Int = 0,
        timestampDelta: UInt32 = 0,
        contentKey: Data
    ) throws -> Data {
        let request = AppleRFBMessages.pointerEventEncryptionRequest(
            buttons: buttons,
            x: x,
            y: y,
            clickCount: clickCount,
            timestampDelta: timestampDelta
        )
        return try message(for: request, contentKey: contentKey)
    }

    static func keyEvent(
        isDown: Bool,
        keySymbol: UInt32,
        timestampDelta: UInt32,
        keyboardType: UInt16,
        keyCode: UInt16,
        subtype: UInt8 = 1,
        contentKey: Data
    ) throws -> Data {
        let request = AppleRFBMessages.keyEventEncryptionRequest(
            isDown: isDown,
            keySymbol: keySymbol,
            timestampDelta: timestampDelta,
            keyboardType: keyboardType,
            keyCode: keyCode,
            subtype: subtype
        )
        return try message(for: request, contentKey: contentKey)
    }

    private static func message(
        for request: AppleRFBInputEncryptionRequest,
        contentKey: Data
    ) throws -> Data {
        request.header + (try Cryptography.encryptAESECB(
            request.plaintextBlock,
            key: contentKey
        ))
    }
}
