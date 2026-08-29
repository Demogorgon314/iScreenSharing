import Foundation

public struct AppleScrollWheelEvent: Equatable, Sendable {
    public let deltaX: Int16
    public let deltaY: Int16
    public let deltaZ: Int16
    public let fixedDeltaX: Int32
    public let fixedDeltaY: Int32
    public let fixedDeltaZ: Int32
    public let pointDeltaX: Int32
    public let pointDeltaY: Int32
    public let pointDeltaZ: Int32
    public let scrollPhase: UInt32
    public let momentumPhase: UInt32
    public let scrollCount: UInt32
    public let flags: UInt32

    public init(
        deltaX: Int16,
        deltaY: Int16,
        deltaZ: Int16,
        fixedDeltaX: Int32,
        fixedDeltaY: Int32,
        fixedDeltaZ: Int32,
        pointDeltaX: Int32,
        pointDeltaY: Int32,
        pointDeltaZ: Int32,
        scrollPhase: UInt32,
        momentumPhase: UInt32,
        scrollCount: UInt32,
        flags: UInt32
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.deltaZ = deltaZ
        self.fixedDeltaX = fixedDeltaX
        self.fixedDeltaY = fixedDeltaY
        self.fixedDeltaZ = fixedDeltaZ
        self.pointDeltaX = pointDeltaX
        self.pointDeltaY = pointDeltaY
        self.pointDeltaZ = pointDeltaZ
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.scrollCount = scrollCount
        self.flags = flags
    }
}

/// The deterministic portion of an Apple encrypted input message.
/// Encrypt `plaintextBlock` with the session content key using AES-ECB without
/// padding, then append the ciphertext to `header`.
public struct AppleRFBInputEncryptionRequest: Equatable, Sendable {
    public let header: Data
    public let plaintextBlock: Data

    fileprivate init(header: Data, plaintextBlock: Data) {
        precondition(plaintextBlock.count == 16)
        self.header = header
        self.plaintextBlock = plaintextBlock
    }
}

public enum AppleRFBMessages {
    private static let highPerformanceEncodings: [Int32] = [
        1010, 1011, 1002, 1104, 1100,
        -223, 1101, 1105, 1107, 1109, 1110,
    ]

    private static let viewerCommandMask = Data([
        0xb0, 0x00, 0x08, 0x03, 0x90, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    public static let setEncryption = Data([
        0x12, 0x00,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
    ])

    public static let postEncryptionToggle = Data([
        0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00,
    ])

    public static let selectCombinedDisplays = Data([
        0x0d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])

    public static func selectDisplay(_ displayID: UInt32) -> Data {
        var message = Data([0x0d, 0x00, 0x00, 0x00])
        message.appendAppleUInt32BE(displayID)
        return message
    }

    public static func viewerInfo(
        applicationVersion: (UInt32, UInt32, UInt32) = (5, 3, 0),
        operatingSystemVersion: (UInt32, UInt32, UInt32) = (15, 7, 7)
    ) -> Data {
        var message = Data([0x21, 0x00])
        message.appendAppleUInt16BE(0x003e)
        message.appendAppleUInt16BE(1)
        message.appendAppleUInt32BE(2)
        message.appendAppleUInt32BE(applicationVersion.0)
        message.appendAppleUInt32BE(applicationVersion.1)
        message.appendAppleUInt32BE(applicationVersion.2)
        message.appendAppleUInt32BE(operatingSystemVersion.0)
        message.appendAppleUInt32BE(operatingSystemVersion.1)
        message.appendAppleUInt32BE(operatingSystemVersion.2)
        message.append(viewerCommandMask)
        return message
    }

    public static func setEncodings() throws -> Data {
        try setEncodings(highPerformanceEncodings)
    }

    public static func setEncodings(_ encodings: [Int32]) throws -> Data {
        guard encodings.count <= Int(UInt16.max) else {
            throw AppleRFBMessageError.tooManyEncodings
        }
        var message = Data([0x02, 0x00])
        message.appendAppleUInt16BE(UInt16(encodings.count))
        for encoding in encodings {
            message.appendAppleInt32BE(encoding)
        }
        return message
    }

    public static func framebufferUpdateRequest(
        incremental: Bool = false,
        width: UInt16 = .max,
        height: UInt16 = .max
    ) -> Data {
        var message = Data([0x03, incremental ? 0x01 : 0x00])
        message.appendAppleUInt16BE(0)
        message.appendAppleUInt16BE(0)
        message.appendAppleUInt16BE(width)
        message.appendAppleUInt16BE(height)
        return message
    }

    public static func autoFramebufferUpdate(
        width: UInt16 = .max,
        height: UInt16 = .max,
        intervalMilliseconds: UInt32 = 0
    ) -> Data {
        var message = Data([0x09, 0x00])
        message.appendAppleUInt16BE(1)
        message.appendAppleUInt32BE(intervalMilliseconds)
        message.appendAppleUInt16BE(0)
        message.appendAppleUInt16BE(0)
        message.appendAppleUInt16BE(width)
        message.appendAppleUInt16BE(height)
        return message
    }

    public static func controlMode(observing: Bool) -> Data {
        var message = Data([0x0a, 0x00])
        message.appendAppleUInt16BE(observing ? 0 : 1)
        return message
    }

    public static func scrollWheelEvent(
        _ event: AppleScrollWheelEvent,
        x: UInt16,
        y: UInt16
    ) -> Data {
        var message = Data([0x17, 0x00])
        message.appendAppleUInt16BE(54)
        message.appendAppleUInt16BE(1)
        message.appendAppleUInt16BE(11)
        message.appendAppleUInt16BE(UInt16(bitPattern: event.deltaX))
        message.appendAppleUInt16BE(UInt16(bitPattern: event.deltaY))
        message.appendAppleUInt16BE(UInt16(bitPattern: event.deltaZ))
        message.appendAppleInt32BE(event.fixedDeltaX)
        message.appendAppleInt32BE(event.fixedDeltaY)
        message.appendAppleInt32BE(event.fixedDeltaZ)
        message.appendAppleInt32BE(event.pointDeltaX)
        message.appendAppleInt32BE(event.pointDeltaY)
        message.appendAppleInt32BE(event.pointDeltaZ)
        message.appendAppleUInt32BE(event.scrollPhase)
        message.appendAppleUInt32BE(event.momentumPhase)
        message.appendAppleUInt32BE(event.scrollCount)
        message.appendAppleUInt32BE(event.flags)
        message.appendAppleUInt16BE(x)
        message.appendAppleUInt16BE(y)
        return message
    }

    public static func pointerEventEncryptionRequest(
        buttons: UInt8,
        x: UInt16,
        y: UInt16,
        clickCount: Int = 0,
        timestampDelta: UInt32 = 0
    ) -> AppleRFBInputEncryptionRequest {
        var plaintext = Data(repeating: 0, count: 10)
        plaintext.writeAppleUInt32BE(timestampDelta, at: 6)
        plaintext.append(0xff)
        plaintext.append(buttons)
        plaintext.appendAppleUInt16BE(x)
        plaintext.appendAppleUInt16BE(y)
        let flags = UInt8(1 | ((max(0, clickCount) & 7) << 1))
        return AppleRFBInputEncryptionRequest(
            header: Data([0x10, flags]),
            plaintextBlock: plaintext
        )
    }

    public static func keyEventEncryptionRequest(
        isDown: Bool,
        keySymbol: UInt32,
        timestampDelta: UInt32,
        keyboardType: UInt16,
        keyCode: UInt16,
        subtype: UInt8 = 1
    ) -> AppleRFBInputEncryptionRequest {
        var plaintext = Data([0xff, isDown ? 1 : 0])
        plaintext.appendAppleUInt32BE(keySymbol)
        plaintext.appendAppleUInt32BE(timestampDelta)
        plaintext.appendAppleUInt16BE(0)
        plaintext.appendAppleUInt16BE(keyboardType)
        plaintext.appendAppleUInt16BE(keyCode)
        return AppleRFBInputEncryptionRequest(
            header: Data([0x10, subtype]),
            plaintextBlock: plaintext
        )
    }
}

public enum AppleRFBMessageError: LocalizedError, Equatable {
    case tooManyEncodings

    public var errorDescription: String? {
        "The RFB encoding list exceeds the wire format limit."
    }
}

private extension Data {
    mutating func appendAppleUInt16BE(_ value: UInt16) {
        BigEndianWire.append(value, to: &self)
    }

    mutating func appendAppleUInt32BE(_ value: UInt32) {
        BigEndianWire.append(value, to: &self)
    }

    mutating func appendAppleInt32BE(_ value: Int32) {
        BigEndianWire.append(UInt32(bitPattern: value), to: &self)
    }

    mutating func writeAppleUInt32BE(_ value: UInt32, at offset: Int) {
        precondition(BigEndianWire.write(value, to: &self, at: offset))
    }
}
