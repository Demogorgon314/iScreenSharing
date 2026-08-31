import Foundation

/// The display metadata and advertised server-command capabilities from ServerInit.
public struct RFBServerInfo: Equatable, Sendable {
    /// Largest framebuffer width or height accepted by the native RFB client.
    public static let maximumFramebufferDimension: UInt16 = 60_000

    public let width: UInt16
    public let height: UInt16
    public let pixelFormat: Data
    public let name: String
    public let serverFlags: UInt32?
    public let commandBitmap: Data?

    public init(
        width: UInt16,
        height: UInt16,
        pixelFormat: Data,
        name: String,
        serverFlags: UInt32? = nil,
        commandBitmap: Data? = nil
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
        self.serverFlags = serverFlags
        self.commandBitmap = commandBitmap
    }

    public func supportsServerCommand(_ command: UInt8) -> Bool {
        guard let commandBitmap, commandBitmap.count == 16 else { return false }
        let byteIndex = Int(command >> 3)
        guard byteIndex < commandBitmap.count else { return false }
        let mask = UInt8(1 << (7 - (command & 7)))
        return commandBitmap[byteIndex] & mask != 0
    }

    public var supportsViewerToHostFileTransfer: Bool {
        supportsServerCommand(32) && supportsServerCommand(34)
    }

    public var supportsCopyPaste: Bool {
        supportsServerCommand(11) && supportsServerCommand(31)
    }

    public var supportsSharedPasteboard: Bool {
        supportsCopyPaste && supportsServerCommand(21)
    }

    /// Rejects dimensions outside the framebuffer range accepted during ServerInit.
    public static func validateFramebufferDimensions(
        width: UInt16,
        height: UInt16
    ) throws {
        guard width > 0,
              height > 0,
              width <= maximumFramebufferDimension,
              height <= maximumFramebufferDimension else {
            throw RFBServerInitError.invalidDimensions
        }
    }

    public static func parse(header: Data, nameData: Data) throws -> Self {
        guard header.count == 24,
              let rawNameLength = BigEndianWire.uint32(from: header, at: 20),
              let nameLength = Int(exactly: rawNameLength),
              nameData.count == nameLength,
              let width = BigEndianWire.uint16(from: header, at: 0),
              let height = BigEndianWire.uint16(from: header, at: 2) else {
            throw RFBServerInitError.invalidMessage
        }
        try validateFramebufferDimensions(width: width, height: height)

        let enhanced: (flags: UInt32?, commands: Data?, name: Data)
        if nameData.count >= 2,
           BigEndianWire.uint16(from: nameData, at: 0) == 0 {
            guard nameData.count >= 22,
                  let flags = BigEndianWire.uint32(from: nameData, at: 2) else {
                throw RFBServerInitError.invalidMessage
            }
            enhanced = (
                flags,
                nameData.subdata(in: 6..<22),
                nameData.subdata(in: 22..<nameData.count)
            )
        } else {
            enhanced = (nil, nil, nameData)
        }
        guard let name = String(data: enhanced.name, encoding: .utf8) else {
            throw RFBServerInitError.invalidMessage
        }
        return Self(
            width: width,
            height: height,
            pixelFormat: header.subdata(in: 4..<20),
            name: name,
            serverFlags: enhanced.flags,
            commandBitmap: enhanced.commands
        )
    }
}

public enum RFBServerInitError: LocalizedError, Equatable {
    case invalidMessage
    case invalidDimensions

    public var errorDescription: String? {
        switch self {
        case .invalidMessage:
            "The Mac returned an invalid display description."
        case .invalidDimensions:
            "The Mac returned an invalid display size."
        }
    }
}
