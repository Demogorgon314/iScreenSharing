import Foundation

public extension AppleEncryptedRecordLayer {
    func encryptPointerEvent(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        clickCount: Int = 0,
        timestampDelta: UInt32 = 0
    ) throws -> Data {
        try encryptInputMessage(AppleRFBMessages.pointerEventEncryptionRequest(
            buttons: buttons,
            x: x,
            y: y,
            clickCount: clickCount,
            timestampDelta: timestampDelta
        ))
    }

    func encryptKeyEvent(
        isDown: Bool,
        keySymbol: UInt32,
        timestampDelta: UInt32,
        keyboardType: UInt16,
        keyCode: UInt16,
        subtype: UInt8 = 1
    ) throws -> Data {
        try encryptInputMessage(AppleRFBMessages.keyEventEncryptionRequest(
            isDown: isDown,
            keySymbol: keySymbol,
            timestampDelta: timestampDelta,
            keyboardType: keyboardType,
            keyCode: keyCode,
            subtype: subtype
        ))
    }

    private func encryptInputMessage(_ request: AppleRFBInputEncryptionRequest) throws -> Data {
        do {
            return request.header + (try AppleProtocolAES.encryptECB(
                request.plaintextBlock,
                key: contentKey
            ))
        } catch {
            throw AppleEncryptedRecordError.encryptionFailed
        }
    }
}
