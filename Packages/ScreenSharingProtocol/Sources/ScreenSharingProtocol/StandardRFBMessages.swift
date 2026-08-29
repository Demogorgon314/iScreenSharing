import Foundation

/// The 16-byte RFB pixel-format value negotiated by Standard mode.
public struct StandardRFBPixelFormat: Equatable, Sendable {
    /// Storage width of one source pixel.
    public let bitsPerPixel: UInt8
    /// Number of meaningful color bits in one source pixel.
    public let depth: UInt8
    /// Maximum encoded red component.
    public let redMaximum: UInt16
    /// Maximum encoded green component.
    public let greenMaximum: UInt16
    /// Maximum encoded blue component.
    public let blueMaximum: UInt16
    /// Least-significant bit position of the red component.
    public let redShift: UInt8
    /// Least-significant bit position of the green component.
    public let greenShift: UInt8
    /// Least-significant bit position of the blue component.
    public let blueShift: UInt8

    /// Creates an RFB true-color pixel-format value.
    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        redMaximum: UInt16,
        greenMaximum: UInt16,
        blueMaximum: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.redMaximum = redMaximum
        self.greenMaximum = greenMaximum
        self.blueMaximum = blueMaximum
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// The storage width implied by `bitsPerPixel`.
    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// The full-color little-endian format used by the Standard mode client.
    public static let standard = Self(
        bitsPerPixel: 32,
        depth: 24,
        redMaximum: 255,
        greenMaximum: 255,
        blueMaximum: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    var wireData: Data {
        var data = Data([bitsPerPixel, depth, 0, 1])
        BigEndianWire.append(redMaximum, to: &data)
        BigEndianWire.append(greenMaximum, to: &data)
        BigEndianWire.append(blueMaximum, to: &data)
        data.append(contentsOf: [redShift, greenShift, blueShift, 0, 0, 0])
        return data
    }
}

/// Fixed client-to-server messages used by Standard RFB mode.
public enum StandardRFBMessages {
    /// Raw framebuffer pixels.
    public static let rawEncoding: Int32 = 0
    /// Copy a rectangle from the current framebuffer.
    public static let copyRectangleEncoding: Int32 = 1
    /// Standard RFB Hextile encoding.
    public static let hextileEncoding: Int32 = 5
    /// Standard persistent Zlib encoding.
    public static let zlibEncoding: Int32 = 6
    /// Apple's one-bit SubZlib encoding.
    public static let subZlibHalftoneEncoding: Int32 = 1_000
    /// Apple's 16-level grayscale SubZlib encoding.
    public static let subZlib16GrayEncoding: Int32 = 1_001
    /// Apple's RGB555 SubZlib encoding.
    public static let subZlibThousandsEncoding: Int32 = 1_002
    /// The standard DesktopSize pseudo-encoding.
    public static let desktopSizeEncoding: Int32 = -223

    /// Requests the shared-desktop form of ClientInit.
    public static let clientInit = Data([1])

    /// Builds SetPixelFormat with little-endian, true-color flags and the supplied 16-byte value.
    public static func setPixelFormat(_ format: StandardRFBPixelFormat) -> Data {
        Data([0, 0, 0, 0]) + format.wireData
    }

    /// Builds SetEncodings while preserving the caller's order and signed pseudo-encodings.
    ///
    /// - Throws: ``StandardRFBMessageError/tooManyEncodings`` when the list
    ///   cannot be represented by the wire format's `UInt16` count.
    public static func setEncodings(_ encodings: [Int32]) throws -> Data {
        do {
            return try RFBEncodingList.message(encodings)
        } catch {
            throw StandardRFBMessageError.tooManyEncodings
        }
    }

    /// Builds the eight-byte Standard RFB keyboard event.
    public static func keyEvent(isDown: Bool, symbol: UInt32) -> Data {
        var data = Data([4, isDown ? 1 : 0, 0, 0])
        BigEndianWire.append(symbol, to: &data)
        return data
    }

    /// Builds the six-byte Standard RFB pointer event.
    public static func pointerEvent(buttons: UInt8, x: UInt16, y: UInt16) -> Data {
        var data = Data([5, buttons])
        BigEndianWire.append(x, to: &data)
        BigEndianWire.append(y, to: &data)
        return data
    }
}

/// Observable failures while encoding Standard RFB client messages.
public enum StandardRFBMessageError: LocalizedError, Equatable {
    /// The encoding count cannot be represented by the message's `UInt16` field.
    case tooManyEncodings

    public var errorDescription: String? {
        "The RFB encoding list exceeds the wire format limit."
    }
}
