import Foundation
import enum ScreenSharingProtocol.StandardRFBMessages
import struct ScreenSharingProtocol.StandardRFBPixelFormat
import XCTest
@testable import iScreenSharing

final class StandardRFBCodecTests: XCTestCase {
    func testBuildsQualitySpecificEncodingPreferences() {
        XCTAssertEqual(
            StandardRFBMessages.setEncodings(for: .high),
            Data([
                2, 0, 0, 5,
                0, 0, 0, 1,
                0, 0, 0, 6,
                0, 0, 0, 0,
                0, 0, 0, 5,
                0xff, 0xff, 0xff, 0x21,
            ])
        )
        XCTAssertEqual(
            StandardRFBMessages.setEncodings(for: .balanced),
            Data([
                2, 0, 0, 6,
                0, 0, 3, 0xea,
                0, 0, 0, 1,
                0, 0, 0, 6,
                0, 0, 0, 0,
                0, 0, 0, 5,
                0xff, 0xff, 0xff, 0x21,
            ])
        )
        XCTAssertEqual(
            StandardRFBMessages.setEncodings(for: .medium),
            Data([
                2, 0, 0, 6,
                0, 0, 3, 0xe9,
                0, 0, 0, 1,
                0, 0, 0, 6,
                0, 0, 0, 0,
                0, 0, 0, 5,
                0xff, 0xff, 0xff, 0x21,
            ])
        )
        XCTAssertEqual(
            StandardRFBMessages.setEncodings(for: .lowBandwidth),
            Data([
                2, 0, 0, 6,
                0, 0, 3, 0xe8,
                0, 0, 0, 1,
                0, 0, 0, 6,
                0, 0, 0, 0,
                0, 0, 0, 5,
                0xff, 0xff, 0xff, 0x21,
            ])
        )
    }

    func testReducedColorStartupProfiles() {
        XCTAssertEqual(
            StandardRFBMessages.qualityProfile(for: .high).startupQuality,
            .high
        )
        XCTAssertEqual(
            StandardRFBMessages.qualityProfile(for: .medium).startupQuality,
            .medium
        )
        XCTAssertEqual(
            StandardRFBMessages.qualityProfile(for: .balanced).startupQuality,
            .high
        )
        XCTAssertEqual(
            StandardRFBMessages.qualityProfile(for: .lowBandwidth).startupQuality,
            .high
        )
    }

    func testDecodesPersistentZlibRectangles() throws {
        let decoder = try StandardRFBZlibDecoder()
        XCTAssertEqual(
            try decoder.decode(
                Data([120, 156, 98, 100, 98, 102, 96, 97, 101, 99, 0, 0, 0, 0, 255, 255]),
                expectedSize: 8
            ),
            Data([1, 2, 3, 0, 4, 5, 6, 0])
        )
        XCTAssertEqual(
            try decoder.decode(
                Data([98, 231, 224, 100, 224, 226, 230, 97, 0, 0, 0, 0, 255, 255]),
                expectedSize: 8
            ),
            Data([7, 8, 9, 0, 10, 11, 12, 0])
        )
    }

    func testDecodesHextileBackgroundAndColoredSubrectangle() async throws {
        let input = HextileInput(Data([
            UInt8(2 | 8 | 16),
            0x10, 0x20, 0x30, 0,
            1,
            0x60, 0x50, 0x40, 0,
            0x11, 0x11,
        ]))

        let output = try await StandardRFBHextileDecoder.decode(
            width: 4,
            height: 3,
            pixelFormat: .standard,
            read: { try input.read($0) }
        )

        XCTAssertEqual(Array(output[0..<4]), [0x10, 0x20, 0x30, 0xff])
        XCTAssertEqual(Array(output[20..<24]), [0x60, 0x50, 0x40, 0xff])
        XCTAssertEqual(Array(output[24..<28]), [0x60, 0x50, 0x40, 0xff])
        XCTAssertEqual(Array(output[44..<48]), [0x10, 0x20, 0x30, 0xff])
    }

    func testDecodesNative32BitPixelFormatToBGRA() throws {
        XCTAssertEqual(
            try StandardRFBPixelFormat.standard.decodeBGRA(
                Data([0x33, 0x22, 0x11, 0]),
                pixelCount: 1
            ),
            Data([0x33, 0x22, 0x11, 0xff])
        )
        XCTAssertThrowsError(
            try StandardRFBPixelFormat.standard.decodeBGRA(
                Data([0]),
                pixelCount: 1
            )
        )
    }

    func testDecodesNative32BitPixelFormatIntoPaddedDestination() throws {
        let source = Data([
            0x30, 0x20, 0x10, 0x7f,
            0x60, 0x50, 0x40, 0x00,
        ])
        var destination = Data(repeating: 0xee, count: 20)

        try destination.withUnsafeMutableBytes { bytes in
            try StandardRFBPixelFormat.standard.decodeBGRA(
                source,
                width: 1,
                height: 2,
                into: bytes,
                destinationOffset: 4,
                destinationBytesPerRow: 8
            )
        }

        XCTAssertEqual(
            destination,
            Data([
                0xee, 0xee, 0xee, 0xee,
                0x30, 0x20, 0x10, 0xff,
                0xee, 0xee, 0xee, 0xee,
                0x60, 0x50, 0x40, 0xff,
                0xee, 0xee, 0xee, 0xee,
            ])
        )
    }

    func testQualityLevelsRoundTripAndClamp() {
        XCTAssertEqual(StandardRFBQuality(level: -1), .lowBandwidth)
        XCTAssertEqual(StandardRFBQuality(level: 0), .lowBandwidth)
        XCTAssertEqual(StandardRFBQuality(level: 1), .medium)
        XCTAssertEqual(StandardRFBQuality(level: 2), .balanced)
        XCTAssertEqual(StandardRFBQuality(level: 3), .high)
        XCTAssertEqual(StandardRFBQuality(level: 4), .high)
        for quality in StandardRFBQuality.allCases {
            XCTAssertEqual(StandardRFBQuality(level: quality.level), quality)
        }
    }

    func testDecodesNativeThousandsRGB555VectorIntoStridedFramebuffer() throws {
        var framebuffer = Data(repeating: 0xaa, count: 48)
        try framebuffer.withUnsafeMutableBytes { destination in
            try StandardRFBThousandsDecoder.decode(
                Data([
                    0x7c, 0x00, 0x03, 0xe0, 0x00, 0x1f,
                    0x7f, 0xff, 0x7f, 0xff, 0x7f, 0xff,
                ]),
                width: 3,
                height: 2,
                into: destination,
                destinationOffset: 4,
                destinationBytesPerRow: 24
            )
        }

        XCTAssertEqual(Array(framebuffer[4..<16]), [
            0, 0, 248, 255,
            0, 248, 0, 255,
            248, 0, 0, 255,
        ])
        XCTAssertEqual(Array(framebuffer[28..<40]), [
            255, 255, 255, 255,
            255, 255, 255, 255,
            248, 248, 248, 255,
        ])
        XCTAssertEqual(Array(framebuffer[16..<28]), Array(repeating: 0xaa, count: 12))
        XCTAssertEqual(Array(framebuffer[40..<48]), Array(repeating: 0xaa, count: 8))
    }

    func testDecodesHalftoneRowsMSBFirstWithByteAlignedPadding() throws {
        var framebuffer = Data(repeating: 0xaa, count: 96)
        try framebuffer.withUnsafeMutableBytes { destination in
            try StandardRFBHalftoneDecoder.decode(
                Data([0b1010_0001, 0b1100_0000, 0b0101_1110, 0b0000_0000]),
                width: 10,
                height: 2,
                into: destination,
                destinationOffset: 8,
                destinationBytesPerRow: 48
            )
        }

        XCTAssertEqual(Array(framebuffer[8..<48]), [
            255, 255, 255, 255, 0, 0, 0, 255,
            255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255,
        ])
        XCTAssertEqual(Array(framebuffer[56..<96]), [
            0, 0, 0, 255, 255, 255, 255, 255,
            0, 0, 0, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 0, 0, 0, 255,
        ])
        XCTAssertEqual(Array(framebuffer[0..<8]), Array(repeating: 0xaa, count: 8))
        XCTAssertEqual(Array(framebuffer[48..<56]), Array(repeating: 0xaa, count: 8))
    }

    func testRejectsMalformedHalftonePayload() {
        var framebuffer = Data(count: 8)
        XCTAssertThrowsError(
            try framebuffer.withUnsafeMutableBytes { destination in
                try StandardRFBHalftoneDecoder.decode(
                    Data([0x80]),
                    width: 9,
                    height: 1,
                    into: destination,
                    destinationOffset: 0,
                    destinationBytesPerRow: 36
                )
            }
        )
    }

    func testDecodesGrayscaleRowsHighNibbleFirstWithRowAlignedPadding() throws {
        var framebuffer = Data(repeating: 0xaa, count: 40)
        try framebuffer.withUnsafeMutableBytes { destination in
            try StandardRFBGrayscaleDecoder.decode(
                Data([0x01, 0x2f, 0xef, 0x00]),
                width: 3,
                height: 2,
                into: destination,
                destinationOffset: 4,
                destinationBytesPerRow: 20
            )
        }

        XCTAssertEqual(Array(framebuffer[4..<16]), [
            0, 0, 0, 255,
            16, 16, 16, 255,
            32, 32, 32, 255,
        ])
        XCTAssertEqual(Array(framebuffer[24..<36]), [
            224, 224, 224, 255,
            255, 255, 255, 255,
            0, 0, 0, 255,
        ])
        XCTAssertEqual(Array(framebuffer[0..<4]), Array(repeating: 0xaa, count: 4))
        XCTAssertEqual(Array(framebuffer[16..<24]), Array(repeating: 0xaa, count: 8))
        XCTAssertEqual(Array(framebuffer[36..<40]), Array(repeating: 0xaa, count: 4))
    }

    func testRejectsMalformedGrayscalePayload() {
        var framebuffer = Data(count: 12)
        XCTAssertThrowsError(
            try framebuffer.withUnsafeMutableBytes { destination in
                try StandardRFBGrayscaleDecoder.decode(
                    Data([0x01]),
                    width: 3,
                    height: 1,
                    into: destination,
                    destinationOffset: 0,
                    destinationBytesPerRow: 12
                )
            }
        )
    }

    func testRejectsMalformedThousandsPayload() {
        var framebuffer = Data(count: 12)
        XCTAssertThrowsError(
            try framebuffer.withUnsafeMutableBytes { destination in
                try StandardRFBThousandsDecoder.decode(
                    Data([0x7c, 0x00]),
                    width: 3,
                    height: 1,
                    into: destination,
                    destinationOffset: 0,
                    destinationBytesPerRow: 12
                )
            }
        )
    }

    func testDecodesRGB565DirectlyIntoStridedFramebufferRegion() throws {
        let rgb565 = StandardRFBPixelFormat(
            bitsPerPixel: 16,
            depth: 16,
            redMaximum: 31,
            greenMaximum: 63,
            blueMaximum: 31,
            redShift: 11,
            greenShift: 5,
            blueShift: 0
        )
        var framebuffer = Data(repeating: 0xaa, count: 32)
        try framebuffer.withUnsafeMutableBytes { destination in
            try rgb565.decodeBGRA(
                Data([
                    0x00, 0xf8, 0xe0, 0x07,
                    0x1f, 0x00, 0xff, 0xff,
                ]),
                width: 2,
                height: 2,
                into: destination,
                destinationOffset: 4,
                destinationBytesPerRow: 16
            )
        }

        XCTAssertEqual(Array(framebuffer[0..<4]), [0xaa, 0xaa, 0xaa, 0xaa])
        XCTAssertEqual(Array(framebuffer[4..<12]), [
            0, 0, 255, 255,
            0, 255, 0, 255,
        ])
        XCTAssertEqual(Array(framebuffer[12..<20]), Array(repeating: 0xaa, count: 8))
        XCTAssertEqual(Array(framebuffer[20..<28]), [
            255, 0, 0, 255,
            255, 255, 255, 255,
        ])
        XCTAssertEqual(Array(framebuffer[28..<32]), [0xaa, 0xaa, 0xaa, 0xaa])
    }

    func testTracksOverlappingFramebufferCoverageExactly() {
        var coverage = StandardRFBRegionCoverage(width: 5, height: 2)
        coverage.mark(x: 0, y: 0, width: 3, height: 2)
        coverage.mark(x: 2, y: 0, width: 3, height: 1)

        XCTAssertEqual(coverage.coveredPixelCount, 8)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertTrue(coverage.covers(x: 0, y: 0, width: 5, height: 1))
        XCTAssertFalse(coverage.covers(x: 0, y: 1, width: 5, height: 1))

        coverage.mark(x: 3, y: 1, width: 2, height: 1)
        XCTAssertEqual(coverage.coveredPixelCount, 10)
        XCTAssertTrue(coverage.isComplete)
    }
}

private final class HextileInput: @unchecked Sendable {
    private var data: Data

    init(_ data: Data) {
        self.data = data
    }

    func read(_ length: Int) throws -> Data {
        guard data.count >= length else { throw StandardRFBError.invalidRectangle }
        let result = Data(data.prefix(length))
        data.removeFirst(length)
        return result
    }
}
