import Foundation

struct AppleDisplayRect: Equatable, Sendable {
    let displayID: UInt32
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct AppleDisplayLayout: Equatable, Sendable {
    let scaledWidth: Int
    let scaledHeight: Int
    let backingWidth: Int
    let backingHeight: Int
    let displays: [AppleDisplayRect]

    var canvas: AppleCanvas {
        AppleCanvas(width: backingWidth, height: backingHeight, tileCount: displays.count)
    }
}

enum AppleDisplayConfiguration {
    private static let descriptorHeaderSize = 0x9c
    private static let modeSize = 28
    private static let maximumNameLength = 119
    private static let modes = [
        (pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080),
        (pixelWidth: 2880, pixelHeight: 1800, pointWidth: 1440, pointHeight: 900),
        (pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080),
        (pixelWidth: 2880, pixelHeight: 1620, pointWidth: 1440, pointHeight: 810),
        (pixelWidth: 2624, pixelHeight: 1696, pointWidth: 1312, pointHeight: 848),
    ]

    static func message(
        width: Int,
        height: Int,
        backingScale: Double = 2,
        hdr: Bool = false,
        displayName: String = "iShareScreen Virtual Display"
    ) throws -> Data {
        guard width > 0, height > 0 else {
            throw AppleDisplayConfigurationError.invalidDimensions
        }
        guard backingScale.isFinite, backingScale > 0 else {
            throw AppleDisplayConfigurationError.invalidBackingScale
        }

        let descriptorSize = descriptorHeaderSize + modeSize * modes.count
        var descriptor = Data(repeating: 0, count: descriptorSize)
        descriptor.writeUInt16BE(UInt16(descriptorSize), at: 0)
        let name = Data(displayName.utf8.prefix(maximumNameLength))
        descriptor.replaceSubrange(2..<(2 + name.count), with: name)
        descriptor.writeUInt32BE(1, at: 0x7a)
        descriptor.writeUInt32BE(4, at: 0x7e)
        descriptor.writeUInt32BE(Float(369.4545593261719).bitPattern, at: 0x82)
        descriptor.writeUInt32BE(Float(207.81817626953125).bitPattern, at: 0x86)
        descriptor.writeUInt32BE(3840, at: 0x8a)
        descriptor.writeUInt32BE(2160, at: 0x8e)
        descriptor.writeUInt32BE(7, at: 0x96)
        descriptor.writeUInt16BE(UInt16(modes.count), at: 0x9a)

        let horizontalScale = Double(width) / 1920
        let verticalScale = Double(height) / 1080
        for (index, mode) in modes.enumerated() {
            let pointWidth = Int((Double(mode.pointWidth) * horizontalScale).rounded())
            let pointHeight = Int((Double(mode.pointHeight) * verticalScale).rounded())
            let pixelWidth = Int((Double(pointWidth) * backingScale).rounded())
            let pixelHeight = Int((Double(pointHeight) * backingScale).rounded())
            guard [pointWidth, pointHeight, pixelWidth, pixelHeight].allSatisfy({
                $0 >= 0 && UInt64($0) <= UInt64(UInt32.max)
            }) else {
                throw AppleDisplayConfigurationError.invalidDimensions
            }

            let offset = descriptorHeaderSize + modeSize * index
            descriptor.writeUInt32BE(UInt32(pixelWidth), at: offset)
            descriptor.writeUInt32BE(UInt32(pixelHeight), at: offset + 4)
            descriptor.writeUInt32BE(UInt32(pointWidth), at: offset + 8)
            descriptor.writeUInt32BE(UInt32(pointHeight), at: offset + 12)
            descriptor.writeUInt64BE(60.0.bitPattern, at: offset + 16)
            descriptor.writeUInt32BE(hdr ? 1 : 0, at: offset + 24)
        }

        var message = Data([0x1d, 0])
        message.appendUInt16BE(UInt16(8 + descriptorSize))
        message.appendUInt16BE(1)
        message.appendUInt16BE(1)
        message.appendUInt32BE(0)
        message.append(descriptor)
        return message
    }

    static func layout(from payload: Data) -> AppleDisplayLayout? {
        guard payload.count >= 20,
              let scaledWidth = try? payload.uint16BE(at: 2),
              let scaledHeight = try? payload.uint16BE(at: 4),
              let backingWidth = try? payload.uint16BE(at: 6),
              let backingHeight = try? payload.uint16BE(at: 8),
              let count = try? payload.uint16BE(at: 18),
              count > 0,
              payload.count >= 20 + Int(count) * 56 else { return nil }

        var displays: [AppleDisplayRect] = []
        for index in 0..<Int(count) {
            let offset = 20 + index * 56
            guard let displayID = try? payload.uint32BE(at: offset + 16),
                  let y0 = try? payload.uint16BE(at: offset + 28),
                  let x0 = try? payload.uint16BE(at: offset + 30),
                  let y1 = try? payload.uint16BE(at: offset + 32),
                  let x1 = try? payload.uint16BE(at: offset + 34),
                  x1 > x0, y1 > y0 else { continue }
            displays.append(AppleDisplayRect(
                displayID: displayID,
                x: Int(x0),
                y: Int(y0),
                width: Int(x1 - x0),
                height: Int(y1 - y0)
            ))
        }
        guard !displays.isEmpty else { return nil }
        return AppleDisplayLayout(
            scaledWidth: Int(scaledWidth),
            scaledHeight: Int(scaledHeight),
            backingWidth: Int(backingWidth),
            backingHeight: Int(backingHeight),
            displays: displays
        )
    }
}

enum AppleDisplayConfigurationError: LocalizedError, Equatable {
    case invalidDimensions
    case invalidBackingScale

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "The requested display dimensions are invalid."
        case .invalidBackingScale: "The requested display scale is invalid."
        }
    }
}
