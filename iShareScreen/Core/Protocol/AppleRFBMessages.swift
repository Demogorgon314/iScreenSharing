import Foundation

struct AppleScrollWheelEvent: Equatable, Sendable {
    let deltaX: Int16
    let deltaY: Int16
    let deltaZ: Int16
    let fixedDeltaX: Int32
    let fixedDeltaY: Int32
    let fixedDeltaZ: Int32
    let pointDeltaX: Int32
    let pointDeltaY: Int32
    let pointDeltaZ: Int32
    let scrollPhase: UInt32
    let momentumPhase: UInt32
    let scrollCount: UInt32
    let flags: UInt32
}

enum AppleRFBMessages {
    static let highPerformanceEncodings: [Int32] = [
        1010, 1011, 1002, 1104, 1100,
        -223, 1101, 1105, 1107, 1109, 1110,
    ]

    static let viewerCommandMask = Data([
        0xb0, 0x00, 0x08, 0x03, 0x90, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    static let setEncryption = Data([
        0x12, 0x00,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
    ])

    static let postEncryptionToggle = Data([
        0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00,
    ])

    static let selectCombinedDisplays = Data([
        0x0d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    static func selectDisplay(_ displayID: UInt32) -> Data {
        var message = Data([0x0d, 0x00, 0x00, 0x00])
        message.appendUInt32BE(displayID)
        return message
    }

    static func viewerInfo(
        applicationVersion: (UInt32, UInt32, UInt32) = (5, 3, 0),
        operatingSystemVersion: (UInt32, UInt32, UInt32) = (15, 7, 7)
    ) -> Data {
        var message = Data([0x21, 0x00])
        message.appendUInt16BE(0x003e)
        message.appendUInt16BE(1)
        message.appendUInt32BE(2)
        message.appendUInt32BE(applicationVersion.0)
        message.appendUInt32BE(applicationVersion.1)
        message.appendUInt32BE(applicationVersion.2)
        message.appendUInt32BE(operatingSystemVersion.0)
        message.appendUInt32BE(operatingSystemVersion.1)
        message.appendUInt32BE(operatingSystemVersion.2)
        message.append(viewerCommandMask)
        return message
    }

    static func setEncodings(_ encodings: [Int32] = highPerformanceEncodings) throws -> Data {
        guard encodings.count <= Int(UInt16.max) else {
            throw AppleRFBMessageError.tooManyEncodings
        }
        var message = Data([0x02, 0x00])
        message.appendUInt16BE(UInt16(encodings.count))
        for encoding in encodings {
            message.appendInt32BE(encoding)
        }
        return message
    }

    static func framebufferUpdateRequest(
        incremental: Bool = false,
        width: UInt16 = .max,
        height: UInt16 = .max
    ) -> Data {
        var message = Data([0x03, incremental ? 0x01 : 0x00])
        message.appendUInt16BE(0)
        message.appendUInt16BE(0)
        message.appendUInt16BE(width)
        message.appendUInt16BE(height)
        return message
    }

    static func autoFramebufferUpdate(
        width: UInt16 = .max,
        height: UInt16 = .max,
        selectedScreen: UInt32 = .max
    ) -> Data {
        var message = Data([0x09, 0x00])
        message.appendUInt16BE(1)
        message.appendUInt32BE(selectedScreen)
        message.appendUInt16BE(0)
        message.appendUInt16BE(0)
        message.appendUInt16BE(width)
        message.appendUInt16BE(height)
        return message
    }

    static func controlMode(observing: Bool) -> Data {
        var message = Data([0x0a, 0x00])
        message.appendUInt16BE(observing ? 0 : 1)
        return message
    }

    static func scrollWheelEvent(
        _ event: AppleScrollWheelEvent,
        x: UInt16,
        y: UInt16
    ) -> Data {
        var message = Data([0x17, 0x00])
        message.appendUInt16BE(54)
        message.appendUInt16BE(1)
        message.appendUInt16BE(11)
        message.appendUInt16BE(UInt16(bitPattern: event.deltaX))
        message.appendUInt16BE(UInt16(bitPattern: event.deltaY))
        message.appendUInt16BE(UInt16(bitPattern: event.deltaZ))
        message.appendInt32BE(event.fixedDeltaX)
        message.appendInt32BE(event.fixedDeltaY)
        message.appendInt32BE(event.fixedDeltaZ)
        message.appendInt32BE(event.pointDeltaX)
        message.appendInt32BE(event.pointDeltaY)
        message.appendInt32BE(event.pointDeltaZ)
        message.appendUInt32BE(event.scrollPhase)
        message.appendUInt32BE(event.momentumPhase)
        message.appendUInt32BE(event.scrollCount)
        message.appendUInt32BE(event.flags)
        message.appendUInt16BE(x)
        message.appendUInt16BE(y)
        return message
    }

    static func encryptedPointerEvent(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        clickCount: Int = 0,
        timestampDelta: UInt32 = 0,
        contentKey: Data
    ) throws -> Data {
        var plaintext = Data(repeating: 0, count: 10)
        plaintext.writeUInt32BE(timestampDelta, at: 6)
        plaintext.append(0xff)
        plaintext.append(buttons)
        plaintext.appendUInt16BE(x)
        plaintext.appendUInt16BE(y)
        let flags = UInt8(1 | ((max(0, clickCount) & 7) << 1))
        return Data([0x10, flags]) + (try Cryptography.encryptAESECB(plaintext, key: contentKey))
    }

    static func encryptedKeyEvent(
        isDown: Bool,
        keySymbol: UInt32,
        timestampDelta: UInt32,
        keyboardType: UInt16,
        keyCode: UInt16,
        contentKey: Data
    ) throws -> Data {
        var plaintext = Data([0xff, isDown ? 1 : 0])
        plaintext.appendUInt32BE(keySymbol)
        plaintext.appendUInt32BE(timestampDelta)
        plaintext.appendUInt16BE(0)
        plaintext.appendUInt16BE(keyboardType)
        plaintext.appendUInt16BE(keyCode)
        return Data([0x10, 0x01]) + (try Cryptography.encryptAESECB(plaintext, key: contentKey))
    }
}

enum AppleRFBMessageError: Error {
    case tooManyEncodings
}
