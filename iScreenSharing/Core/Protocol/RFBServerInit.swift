import Foundation

struct RFBServerInfo: Equatable, Sendable {
    let width: UInt16
    let height: UInt16
    let pixelFormat: Data
    let name: String
    let serverFlags: UInt32?
    let commandBitmap: Data?

    init(
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

    func supportsServerCommand(_ command: UInt8) -> Bool {
        guard let commandBitmap, commandBitmap.count == 16 else { return false }
        let byteIndex = Int(command >> 3)
        guard byteIndex < commandBitmap.count else { return false }
        let mask = UInt8(1 << (7 - (command & 7)))
        return commandBitmap[byteIndex] & mask != 0
    }

    var supportsViewerToHostFileTransfer: Bool {
        supportsServerCommand(32) && supportsServerCommand(34)
    }

    var supportsCopyPaste: Bool {
        supportsServerCommand(11) && supportsServerCommand(31)
    }

    var supportsSharedPasteboard: Bool {
        supportsCopyPaste && supportsServerCommand(21)
    }

    static func parse(header: Data, nameData: Data) throws -> Self {
        guard header.count == 24,
              nameData.count == Int(try header.uint32BE(at: 20)) else {
            throw RFBServerInitError.invalidMessage
        }
        let width = try header.uint16BE(at: 0)
        let height = try header.uint16BE(at: 2)
        guard width > 0, height > 0 else {
            throw RFBServerInitError.invalidDimensions
        }
        let enhanced: (flags: UInt32?, commands: Data?, name: Data)
        if nameData.count >= 2, try nameData.uint16BE(at: 0) == 0 {
            guard nameData.count >= 22 else { throw RFBServerInitError.invalidMessage }
            enhanced = (
                try nameData.uint32BE(at: 2),
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

enum RFBServerInitError: LocalizedError, Equatable {
    case invalidMessage
    case invalidDimensions
    case nameTooLong

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            "The Mac returned an invalid display description."
        case .invalidDimensions:
            "The Mac returned an invalid display size."
        case .nameTooLong:
            "The Mac returned a display name that is too large."
        }
    }
}
