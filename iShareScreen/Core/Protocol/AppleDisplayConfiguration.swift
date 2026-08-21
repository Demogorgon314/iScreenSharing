import CoreGraphics
import Foundation

struct AppleDynamicResolutionSize: Equatable, Sendable {
    let width: Int
    let height: Int

    static func normalized(viewport: CGSize) -> AppleDynamicResolutionSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let maximumScale = min(1, 1920 / viewport.width, 1080 / viewport.height)
        let boundedWidth = viewport.width * maximumScale
        let boundedHeight = viewport.height * maximumScale
        let desiredMinimumScale = max(1, 320 / boundedWidth, 200 / boundedHeight)
        let availableScale = min(1920 / boundedWidth, 1080 / boundedHeight)
        let finalScale = min(desiredMinimumScale, availableScale)
        let width = max(2, Int((boundedWidth * finalScale).rounded(.down)) & ~1)
        let height = max(2, Int((boundedHeight * finalScale).rounded(.down)) & ~1)
        return AppleDynamicResolutionSize(width: width, height: height)
    }
}

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

    func canvas(tileCount: Int) -> AppleCanvas {
        AppleCanvas(width: backingWidth, height: backingHeight, tileCount: tileCount)
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
        displayCount: Int = 1,
        displayName: String = "iShareScreen Virtual Display"
    ) throws -> Data {
        guard (1...2).contains(displayCount) else {
            throw AppleDisplayConfigurationError.invalidDisplayCount
        }
        return try message(
            displaySizes: Array(
                repeating: AppleDynamicResolutionSize(width: width, height: height),
                count: displayCount
            ),
            backingScale: backingScale,
            hdr: hdr,
            displayName: displayName
        )
    }

    static func message(
        displaySizes: [AppleDynamicResolutionSize],
        backingScale: Double = 2,
        hdr: Bool = false,
        displayName: String = "iShareScreen Virtual Display"
    ) throws -> Data {
        guard (1...2).contains(displaySizes.count) else {
            throw AppleDisplayConfigurationError.invalidDisplayCount
        }
        guard backingScale.isFinite, backingScale > 0 else {
            throw AppleDisplayConfigurationError.invalidBackingScale
        }
        let maximumDimension = Double(UInt32.max)
        guard displaySizes.allSatisfy({ size in
            size.width > 0 && size.height > 0
                && Double(size.width) * backingScale <= maximumDimension
                && Double(size.height) * backingScale <= maximumDimension
        }) else {
            throw AppleDisplayConfigurationError.invalidDimensions
        }

        let descriptorSize = descriptorHeaderSize + modeSize * modes.count
        let descriptors = try displaySizes.map {
            try descriptor(
                size: $0,
                backingScale: backingScale,
                hdr: hdr,
                displayName: displayName,
                descriptorSize: descriptorSize
            )
        }
        let messageSize = 8 + descriptorSize * descriptors.count
        var message = Data([0x1d, 0])
        message.appendUInt16BE(UInt16(messageSize))
        message.appendUInt16BE(1)
        message.appendUInt16BE(UInt16(descriptors.count))
        message.appendUInt32BE(0)
        descriptors.forEach { message.append($0) }
        return message
    }

    private static func descriptor(
        size: AppleDynamicResolutionSize,
        backingScale: Double,
        hdr: Bool,
        displayName: String,
        descriptorSize: Int
    ) throws -> Data {
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

        let horizontalScale = Double(size.width) / 1920
        let verticalScale = Double(size.height) / 1080
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
        return descriptor
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
    case invalidDisplayCount

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "The requested display dimensions are invalid."
        case .invalidBackingScale: "The requested display scale is invalid."
        case .invalidDisplayCount: "Screen Sharing supports one or two virtual displays."
        }
    }
}
