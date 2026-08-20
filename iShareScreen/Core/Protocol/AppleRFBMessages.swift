import Foundation

enum AppleRFBMessages {
    static let highPerformanceEncodings: [Int32] = [
        1010, 1011, 1002, 6, 16, 1104, 1100,
        -223, 1101, 1105, 1107, 1109, 1110,
    ]

    static let viewerCommandMask = Data([
        0xb0, 0x00, 0x0c, 0x03, 0x90, 0x00, 0x00, 0x00,
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

    static func viewerInfo(
        applicationVersion: (UInt32, UInt32, UInt32) = (6, 1, 0),
        operatingSystemVersion: (UInt32, UInt32, UInt32) = (15, 3, 0)
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

    static func keyEvent(isDown: Bool, keySymbol: UInt32) -> Data {
        var message = Data([0x04, isDown ? 0x01 : 0x00, 0x00, 0x00])
        message.appendUInt32BE(keySymbol)
        return message
    }

    static func encryptedPointerEvent(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        contentKey: Data
    ) throws -> Data {
        var plaintext = Data(repeating: 0, count: 10)
        plaintext.append(0xff)
        plaintext.append(buttons)
        plaintext.appendUInt16BE(x)
        plaintext.appendUInt16BE(y)
        return Data([0x10, 0x00]) + (try Cryptography.encryptAESECB(plaintext, key: contentKey))
    }
}

enum AppleRFBMessageError: Error {
    case tooManyEncodings
}
