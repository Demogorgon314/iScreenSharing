import Accelerate
import Foundation
import enum ScreenSharingProtocol.StandardRFBMessages
import struct ScreenSharingProtocol.StandardRFBPixelFormat
import zlib

extension StandardRFBPixelFormat {
    var isNativeBGRX: Bool {
        bitsPerPixel == 32
            && redMaximum == 255
            && greenMaximum == 255
            && blueMaximum == 255
            && redShift == 16
            && greenShift == 8
            && blueShift == 0
    }

    func decodeBGRA(_ source: Data, pixelCount: Int) throws -> Data {
        guard pixelCount >= 0,
              source.count == pixelCount * bytesPerPixel else {
            throw StandardRFBError.invalidRectangle
        }
        var output = Data(count: pixelCount * 4)
        try output.withUnsafeMutableBytes { destination in
            try decodeBGRA(
                source,
                width: pixelCount,
                height: 1,
                into: destination,
                destinationOffset: 0,
                destinationBytesPerRow: pixelCount * 4
            )
        }
        return output
    }

    func decodeBGRA(
        _ source: Data,
        width: Int,
        height: Int,
        into destination: UnsafeMutableRawBufferPointer,
        destinationOffset: Int,
        destinationBytesPerRow: Int
    ) throws {
        guard width > 0, height > 0, destinationOffset >= 0,
              destinationBytesPerRow >= width * 4,
              source.count == width * height * bytesPerPixel else {
            throw StandardRFBError.invalidRectangle
        }
        let requiredBytes = destinationOffset + (height - 1) * destinationBytesPerRow + width * 4
        guard requiredBytes <= destination.count,
              let destinationBase = destination.baseAddress else {
            throw StandardRFBError.invalidRectangle
        }
        try source.withUnsafeBytes { sourceBytes in
            let source = sourceBytes.bindMemory(to: UInt8.self)
            if isNativeBGRX {
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress!),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBase.advanced(by: destinationOffset),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: destinationBytesPerRow
                )
                let status = vImageOverwriteChannelsWithScalar_ARGB8888(
                    255,
                    &sourceBuffer,
                    &destinationBuffer,
                    0x1,
                    vImage_Flags(kvImageNoFlags)
                )
                guard status == kvImageNoError else {
                    throw StandardRFBError.invalidRectangle
                }
                return
            }
            if isRGB565 {
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress!),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 2
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBase.advanced(by: destinationOffset),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: destinationBytesPerRow
                )
                let status = vImageConvert_RGB565toBGRA8888(
                    255,
                    &sourceBuffer,
                    &destinationBuffer,
                    vImage_Flags(kvImageNoFlags)
                )
                guard status == kvImageNoError else {
                    throw StandardRFBError.invalidRectangle
                }
                return
            }
            for row in 0..<height {
                let sourcePixelOffset = row * width
                let destinationRow = destinationBase.advanced(
                    by: destinationOffset + row * destinationBytesPerRow
                )
                let destinationBytes = destinationRow.assumingMemoryBound(to: UInt8.self)
                for column in 0..<width {
                    let sourceIndex = sourcePixelOffset + column
                    let value: UInt32
                    switch bytesPerPixel {
                    case 4:
                        let offset = sourceIndex * 4
                        value = UInt32(source[offset])
                            | UInt32(source[offset + 1]) << 8
                            | UInt32(source[offset + 2]) << 16
                            | UInt32(source[offset + 3]) << 24
                    case 2:
                        let offset = sourceIndex * 2
                        value = UInt32(source[offset]) | UInt32(source[offset + 1]) << 8
                    default:
                        value = UInt32(source[sourceIndex])
                    }
                    let destinationPixelOffset = column * 4
                    destinationBytes[destinationPixelOffset] = Self.expand(
                        (value >> UInt32(blueShift)) & UInt32(blueMaximum),
                        maximum: blueMaximum
                    )
                    destinationBytes[destinationPixelOffset + 1] = Self.expand(
                        (value >> UInt32(greenShift)) & UInt32(greenMaximum),
                        maximum: greenMaximum
                    )
                    destinationBytes[destinationPixelOffset + 2] = Self.expand(
                        (value >> UInt32(redShift)) & UInt32(redMaximum),
                        maximum: redMaximum
                    )
                    destinationBytes[destinationPixelOffset + 3] = 255
                }
            }
        }
    }

    private static func expand(_ value: UInt32, maximum: UInt16) -> UInt8 {
        UInt8((value * 255 + UInt32(maximum) / 2) / UInt32(maximum))
    }

    private var isRGB565: Bool {
        bitsPerPixel == 16
            && redMaximum == 31
            && greenMaximum == 63
            && blueMaximum == 31
            && redShift == 11
            && greenShift == 5
            && blueShift == 0
    }

}

enum StandardRFBHalftoneDecoder {
    static func packedByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw StandardRFBError.invalidRectangle }
        let (paddedWidth, paddingOverflow) = width.addingReportingOverflow(7)
        guard !paddingOverflow else { throw StandardRFBError.invalidRectangle }
        let packedBytesPerRow = paddedWidth / 8
        let (byteCount, sizeOverflow) = packedBytesPerRow.multipliedReportingOverflow(by: height)
        guard !sizeOverflow else { throw StandardRFBError.invalidRectangle }
        return byteCount
    }

    static func decode(
        _ source: Data,
        width: Int,
        height: Int,
        into destination: UnsafeMutableRawBufferPointer,
        destinationOffset: Int,
        destinationBytesPerRow: Int
    ) throws {
        let packedBytesPerRow = try packedByteCount(width: width, height: 1)
        let expectedByteCount = try packedByteCount(width: width, height: height)
        guard source.count == expectedByteCount,
              destinationOffset >= 0,
              destinationBytesPerRow >= width * 4 else {
            throw StandardRFBError.invalidRectangle
        }
        let requiredBytes = destinationOffset + (height - 1) * destinationBytesPerRow + width * 4
        guard requiredBytes <= destination.count,
              let destinationBase = destination.baseAddress else {
            throw StandardRFBError.invalidRectangle
        }
        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else { throw StandardRFBError.invalidRectangle }
        var grayscale = Data(count: pixelCount)
        try source.withUnsafeBytes { sourceBytes in
            try grayscale.withUnsafeMutableBytes { grayscaleBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let grayscaleBase = grayscaleBytes.baseAddress else {
                    throw StandardRFBError.invalidRectangle
                }
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBase),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: packedBytesPerRow
                )
                var grayscaleBuffer = vImage_Buffer(
                    data: grayscaleBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBase.advanced(by: destinationOffset),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: destinationBytesPerRow
                )
                let flags = vImage_Flags(kvImageNoFlags)
                guard vImageConvert_Planar1toPlanar8(
                    &sourceBuffer,
                    &grayscaleBuffer,
                    flags
                ) == kvImageNoError,
                    vImageConvert_Planar8ToBGRX8888(
                        &grayscaleBuffer,
                        &grayscaleBuffer,
                        &grayscaleBuffer,
                        255,
                        &destinationBuffer,
                        flags
                    ) == kvImageNoError else {
                    throw StandardRFBError.invalidRectangle
                }
            }
        }
    }
}

enum StandardRFBGrayscaleDecoder {
    private static let grayscaleTable: [Pixel_8] = (0..<16).map { value in
        Pixel_8(value == 15 ? 255 : value * 16)
    }

    static func packedByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw StandardRFBError.invalidRectangle }
        let (paddedWidth, paddingOverflow) = width.addingReportingOverflow(1)
        guard !paddingOverflow else { throw StandardRFBError.invalidRectangle }
        let packedBytesPerRow = paddedWidth / 2
        let (byteCount, sizeOverflow) = packedBytesPerRow.multipliedReportingOverflow(by: height)
        guard !sizeOverflow else { throw StandardRFBError.invalidRectangle }
        return byteCount
    }

    static func decode(
        _ source: Data,
        width: Int,
        height: Int,
        into destination: UnsafeMutableRawBufferPointer,
        destinationOffset: Int,
        destinationBytesPerRow: Int
    ) throws {
        let packedBytesPerRow = try packedByteCount(width: width, height: 1)
        let expectedByteCount = try packedByteCount(width: width, height: height)
        guard source.count == expectedByteCount,
              destinationOffset >= 0,
              destinationBytesPerRow >= width * 4 else {
            throw StandardRFBError.invalidRectangle
        }
        let requiredBytes = destinationOffset + (height - 1) * destinationBytesPerRow + width * 4
        guard requiredBytes <= destination.count,
              let destinationBase = destination.baseAddress else {
            throw StandardRFBError.invalidRectangle
        }
        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else { throw StandardRFBError.invalidRectangle }
        var grayscale = Data(count: pixelCount)
        try source.withUnsafeBytes { sourceBytes in
            try grayscale.withUnsafeMutableBytes { grayscaleBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let grayscaleBase = grayscaleBytes.baseAddress else {
                    throw StandardRFBError.invalidRectangle
                }
                var sourceBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBase),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: packedBytesPerRow
                )
                var grayscaleBuffer = vImage_Buffer(
                    data: grayscaleBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationBuffer = vImage_Buffer(
                    data: destinationBase.advanced(by: destinationOffset),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: destinationBytesPerRow
                )
                let flags = vImage_Flags(kvImageNoFlags)
                let indexedStatus = grayscaleTable.withUnsafeBufferPointer { table in
                    vImageConvert_Indexed4toPlanar8(
                        &sourceBuffer,
                        &grayscaleBuffer,
                        table.baseAddress!,
                        flags
                    )
                }
                guard indexedStatus == kvImageNoError,
                      vImageConvert_Planar8ToBGRX8888(
                          &grayscaleBuffer,
                          &grayscaleBuffer,
                          &grayscaleBuffer,
                          255,
                          &destinationBuffer,
                          flags
                      ) == kvImageNoError else {
                    throw StandardRFBError.invalidRectangle
                }
            }
        }
    }
}

enum StandardRFBThousandsDecoder {
    static func packedByteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw StandardRFBError.invalidRectangle }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 2)
        guard !pixelOverflow, !byteOverflow else { throw StandardRFBError.invalidRectangle }
        return byteCount
    }

    static func decode(
        _ source: Data,
        width: Int,
        height: Int,
        into destination: UnsafeMutableRawBufferPointer,
        destinationOffset: Int,
        destinationBytesPerRow: Int
    ) throws {
        let expectedByteCount = try packedByteCount(width: width, height: height)
        guard source.count == expectedByteCount,
              destinationOffset >= 0,
              destinationBytesPerRow >= width * 4 else {
            throw StandardRFBError.invalidRectangle
        }
        let requiredBytes = destinationOffset + (height - 1) * destinationBytesPerRow + width * 4
        guard requiredBytes <= destination.count,
              let destinationBase = destination.baseAddress else {
            throw StandardRFBError.invalidRectangle
        }

        source.withUnsafeBytes { sourceBytes in
            let bytes = sourceBytes.bindMemory(to: UInt8.self)
            let output = destinationBase.bindMemory(to: UInt8.self, capacity: destination.count)
            var sourceOffset = 0
            for row in 0..<height {
                var destinationOffset = destinationOffset + row * destinationBytesPerRow
                var column = 0
                while column + 1 < width {
                    let first = UInt16(bytes[sourceOffset]) << 8 | UInt16(bytes[sourceOffset + 1])
                    let second = UInt16(bytes[sourceOffset + 2]) << 8 | UInt16(bytes[sourceOffset + 3])
                    if first == 0x7fff, second == 0x7fff {
                        Self.writeWhite(into: output, at: destinationOffset)
                        Self.writeWhite(into: output, at: destinationOffset + 4)
                    } else {
                        Self.write(first, into: output, at: destinationOffset)
                        Self.write(second, into: output, at: destinationOffset + 4)
                    }
                    sourceOffset += 4
                    destinationOffset += 8
                    column += 2
                }
                if column < width {
                    let value = UInt16(bytes[sourceOffset]) << 8 | UInt16(bytes[sourceOffset + 1])
                    Self.write(value, into: output, at: destinationOffset)
                    sourceOffset += 2
                }
            }
        }
    }

    private static func write(
        _ value: UInt16,
        into destination: UnsafeMutablePointer<UInt8>,
        at offset: Int
    ) {
        destination[offset] = UInt8(value & 0x1f) << 3
        destination[offset + 1] = UInt8((value >> 5) & 0x1f) << 3
        destination[offset + 2] = UInt8((value >> 10) & 0x1f) << 3
        destination[offset + 3] = 255
    }

    private static func writeWhite(
        into destination: UnsafeMutablePointer<UInt8>,
        at offset: Int
    ) {
        destination[offset] = 255
        destination[offset + 1] = 255
        destination[offset + 2] = 255
        destination[offset + 3] = 255
    }
}

struct StandardRFBRegionCoverage: Sendable {
    private let width: Int
    private let height: Int
    private let pixelCount: Int
    private var words: [UInt64]
    private(set) var coveredPixelCount = 0

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        pixelCount = width * height
        words = Array(repeating: 0, count: (pixelCount + 63) / 64)
    }

    var isComplete: Bool { coveredPixelCount == pixelCount }

    mutating func mark(x: Int, y: Int, width: Int, height: Int) {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= self.width, y + height <= self.height else { return }
        for row in y..<(y + height) {
            markRange(from: row * self.width + x, count: width)
        }
    }

    func covers(x: Int, y: Int, width: Int, height: Int) -> Bool {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= self.width, y + height <= self.height else { return false }
        for row in y..<(y + height) {
            let start = row * self.width + x
            for index in start..<(start + width) where words[index >> 6] & (1 << (index & 63)) == 0 {
                return false
            }
        }
        return true
    }

    private mutating func markRange(from start: Int, count: Int) {
        let end = start + count
        let firstWord = start >> 6
        let lastWord = (end - 1) >> 6
        if firstWord == lastWord {
            mark(word: firstWord, mask: Self.mask(from: start & 63, through: (end - 1) & 63))
            return
        }
        mark(word: firstWord, mask: UInt64.max << (start & 63))
        if lastWord > firstWord + 1 {
            for word in (firstWord + 1)..<lastWord {
                mark(word: word, mask: UInt64.max)
            }
        }
        mark(word: lastWord, mask: UInt64.max >> (63 - ((end - 1) & 63)))
    }

    private mutating func mark(word: Int, mask: UInt64) {
        let newlyCovered = (~words[word] & mask).nonzeroBitCount
        words[word] |= mask
        coveredPixelCount += newlyCovered
    }

    private static func mask(from firstBit: Int, through lastBit: Int) -> UInt64 {
        (UInt64.max << firstBit) & (UInt64.max >> (63 - lastBit))
    }
}

final class StandardRFBZlibDecoder: @unchecked Sendable {
    private var stream = z_stream()

    init() throws {
        guard inflateInit_(
            &stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw StandardRFBError.invalidRectangle
        }
    }

    deinit {
        inflateEnd(&stream)
    }

    func decode(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard !compressed.isEmpty, expectedSize > 0,
              expectedSize < Int(UInt32.max) else {
            throw StandardRFBError.invalidRectangle
        }
        var output = Data(count: expectedSize + 1)
        let produced = try compressed.withUnsafeBytes { source in
            try output.withUnsafeMutableBytes { destination in
                guard let sourceAddress = source.bindMemory(to: Bytef.self).baseAddress,
                      let destinationAddress = destination.bindMemory(to: Bytef.self).baseAddress else {
                    throw StandardRFBError.invalidRectangle
                }
                stream.next_in = UnsafeMutablePointer(mutating: sourceAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destinationAddress
                stream.avail_out = uInt(destination.count)

                while stream.avail_in > 0 {
                    let previousInput = stream.avail_in
                    let previousOutput = stream.avail_out
                    let status = inflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END,
                          stream.avail_in < previousInput || stream.avail_out < previousOutput else {
                        throw StandardRFBError.invalidRectangle
                    }
                    if status == Z_STREAM_END { break }
                }
                guard stream.avail_in == 0 else {
                    throw StandardRFBError.invalidRectangle
                }
                return destination.count - Int(stream.avail_out)
            }
        }
        guard produced == expectedSize else {
            throw StandardRFBError.invalidRectangle
        }
        output.count = expectedSize
        return output
    }
}

extension StandardRFBMessages {
    struct QualityProfile {
        let quality: StandardRFBQuality
        let preferredEncoding: Int32?

        var startupQuality: StandardRFBQuality {
            switch quality {
            case .balanced, .lowBandwidth: .high
            case .high, .medium: quality
            }
        }

        var requiresInitialRefreshConfirmation: Bool {
            quality != .high
        }
    }

    static func qualityProfile(for quality: StandardRFBQuality) -> QualityProfile {
        let encoding: Int32? = switch quality {
        case .high: nil
        case .balanced: subZlibThousandsEncoding
        case .medium: subZlib16GrayEncoding
        case .lowBandwidth: subZlibHalftoneEncoding
        }
        return QualityProfile(quality: quality, preferredEncoding: encoding)
    }

    static func setEncodings(for quality: StandardRFBQuality) -> Data {
        var encodings = [copyRectangleEncoding, zlibEncoding, rawEncoding, hextileEncoding]
        if let preferredEncoding = qualityProfile(for: quality).preferredEncoding {
            encodings.insert(preferredEncoding, at: 0)
        }
        encodings.append(desktopSizeEncoding)
        return try! setEncodings(encodings)
    }
}

enum StandardRFBHextileDecoder {
    typealias Read = (Int) async throws -> Data

    static func decode(
        width: Int,
        height: Int,
        pixelFormat: StandardRFBPixelFormat,
        read: Read
    ) async throws -> Data {
        guard width > 0, height > 0 else { throw StandardRFBError.invalidRectangle }
        var output = Data(repeating: 0, count: width * height * 4)
        var background = Data([0, 0, 0, 255])
        var foreground = background
        for tileY in stride(from: 0, to: height, by: 16) {
            for tileX in stride(from: 0, to: width, by: 16) {
                let tileWidth = min(16, width - tileX)
                let tileHeight = min(16, height - tileY)
                let subencoding = try await read(1)[0]
                guard subencoding & 0xe0 == 0 else {
                    throw StandardRFBError.invalidRectangle
                }
                if subencoding & 1 != 0 {
                    let pixelCount = tileWidth * tileHeight
                    let raw = try await read(pixelCount * pixelFormat.bytesPerPixel)
                    let pixels = try pixelFormat.decodeBGRA(raw, pixelCount: pixelCount)
                    copy(
                        pixels,
                        sourceWidth: tileWidth,
                        into: &output,
                        destinationWidth: width,
                        x: tileX,
                        y: tileY,
                        width: tileWidth,
                        height: tileHeight
                    )
                    continue
                }
                if subencoding & 2 != 0 {
                    background = try await readPixel(pixelFormat: pixelFormat, read: read)
                }
                fill(
                    background,
                    into: &output,
                    destinationWidth: width,
                    x: tileX,
                    y: tileY,
                    width: tileWidth,
                    height: tileHeight
                )
                if subencoding & 4 != 0 {
                    foreground = try await readPixel(pixelFormat: pixelFormat, read: read)
                }
                guard subencoding & 8 != 0 else { continue }
                let count = Int(try await read(1)[0])
                for _ in 0..<count {
                    let color = subencoding & 16 != 0
                        ? try await readPixel(pixelFormat: pixelFormat, read: read)
                        : foreground
                    let geometry = try await read(2)
                    let x = Int(geometry[0] >> 4)
                    let y = Int(geometry[0] & 0x0f)
                    let subrectWidth = Int(geometry[1] >> 4) + 1
                    let subrectHeight = Int(geometry[1] & 0x0f) + 1
                    guard x + subrectWidth <= tileWidth,
                          y + subrectHeight <= tileHeight else {
                        throw StandardRFBError.invalidRectangle
                    }
                    fill(
                        color,
                        into: &output,
                        destinationWidth: width,
                        x: tileX + x,
                        y: tileY + y,
                        width: subrectWidth,
                        height: subrectHeight
                    )
                }
            }
        }
        return output
    }

    private static func readPixel(
        pixelFormat: StandardRFBPixelFormat,
        read: Read
    ) async throws -> Data {
        try pixelFormat.decodeBGRA(
            await read(pixelFormat.bytesPerPixel),
            pixelCount: 1
        )
    }

    private static func fill(
        _ pixel: Data,
        into output: inout Data,
        destinationWidth: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        output.withUnsafeMutableBytes { destination in
            pixel.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                for row in y..<(y + height) {
                    for column in x..<(x + width) {
                        destinationBase.advanced(by: (row * destinationWidth + column) * 4)
                            .copyMemory(from: sourceBase, byteCount: 4)
                    }
                }
            }
        }
    }

    private static func copy(
        _ source: Data,
        sourceWidth: Int,
        into output: inout Data,
        destinationWidth: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        source.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else { return }
                for row in 0..<height {
                    destinationBase.advanced(by: ((y + row) * destinationWidth + x) * 4)
                        .copyMemory(
                            from: sourceBase.advanced(by: row * sourceWidth * 4),
                            byteCount: width * 4
                        )
                }
            }
        }
    }
}

enum StandardRFBError: LocalizedError, Equatable {
    case invalidRectangle
    case unsupportedEncoding(Int32)
    case unsupportedServerMessage(UInt8)
    case framebufferTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidRectangle:
            "The VNC server returned an invalid framebuffer rectangle."
        case .unsupportedEncoding(let encoding):
            "The VNC server selected unsupported framebuffer encoding \(encoding)."
        case .unsupportedServerMessage(let type):
            "The VNC server sent unsupported message type \(type)."
        case .framebufferTooLarge:
            "The VNC framebuffer is too large to display safely."
        }
    }
}
