import CoreVideo
import XCTest
@testable import iScreenSharing

final class StandardRFBProtocolTests: XCTestCase {
    func testBuildsClientInitializationAndStandardPixelFormat() {
        XCTAssertEqual(StandardRFBMessages.clientInit, Data([1]))
        XCTAssertEqual(
            StandardRFBMessages.setPixelFormat(.standard),
            Data([
                0, 0, 0, 0,
                32, 24, 0, 1,
                0, 255, 0, 255, 0, 255,
                16, 8, 0, 0, 0, 0,
            ])
        )
    }

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

    func testPublishesInitialFramebufferOnlyAfterFullCoverage() async throws {
        var updates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 1, 0, 1,
            0, 0, 0, 0,
            0x10, 0, 0, 0,
        ])
        updates.append(contentsOf: [
            0, 0, 0, 1,
            0, 1, 0, 0, 0, 1, 0, 1,
            0, 0, 0, 0,
            0x20, 0, 0, 0,
        ])
        let transport = StandardRFBTestTransport(receiveData: updates)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 1)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            0x10, 0, 0, 0xff,
            0x20, 0, 0, 0xff,
        ])
        XCTAssertEqual(transport.sentMessages.map(\.first), [0, 2, 3, 9])
    }

    func testBuildsStandardInputMessages() {
        XCTAssertEqual(
            StandardRFBMessages.keyEvent(isDown: true, symbol: 0x41),
            Data([4, 1, 0, 0, 0, 0, 0, 0x41])
        )
        XCTAssertEqual(
            StandardRFBMessages.pointerEvent(buttons: 5, x: 0x1234, y: 0x5678),
            Data([5, 5, 0x12, 0x34, 0x56, 0x78])
        )
    }

    func testReceivesRawRectangleAndPublishesFullCanvasFrame() async throws {
        let transport = StandardRFBTestTransport(receiveData: Self.rawFramebufferUpdate)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 1)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            0x33, 0x22, 0x11, 0xff,
            0x66, 0x55, 0x44, 0xff,
        ])
        let messages = transport.sentMessages
        XCTAssertEqual(messages.map(\.first), [0, 2, 3, 9])
        XCTAssertEqual(messages[2].prefix(2), Data([3, 0]))
    }

    func testReceivesZlibRectangleAndPublishesFullCanvasFrame() async throws {
        var update = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 6,
            0, 0, 0, 16,
        ])
        update.append(contentsOf: [
            120, 156, 98, 100, 98, 102, 96, 97,
            101, 99, 0, 0, 0, 0, 255, 255,
        ])
        let transport = StandardRFBTestTransport(receiveData: update)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            1, 2, 3, 0xff,
            4, 5, 6, 0xff,
        ])
    }

    func testLowBandwidthRetainsFullColorBootstrapUntilConfirmedFrame() async throws {
        var updates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe8,
            0, 0, 0, 9,
            120, 156, 98, 0, 0, 0, 0, 255, 255,
        ])
        updates.append(contentsOf: [
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe8,
            0, 0, 0, 7,
            106, 0, 0, 0, 0, 255, 255,
        ])
        let transport = StandardRFBTestTransport(receiveData: updates)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .lowBandwidth)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 2)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            255, 255, 255, 255,
            0, 0, 0, 255,
        ])
        XCTAssertEqual(transport.sentMessages[1], StandardRFBMessages.setEncodings(for: .high))
        XCTAssertEqual(transport.sentMessages[3], StandardRFBMessages.setEncodings(for: .lowBandwidth))
        XCTAssertEqual(transport.sentMessages.map(\.first), [0, 2, 3, 2, 3, 9, 3])
    }

    func testReceivesBalancedThousandsRectangle() async throws {
        var update = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xea,
            0, 0, 0, 12,
            120, 156, 98, 96, 96, 96, 0, 0, 0, 0, 255, 255,
        ])
        update.append(contentsOf: [
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xea,
            0, 0, 0, 10,
            170, 97, 96, 126, 0, 0, 0, 0, 255, 255,
        ])
        let transport = StandardRFBTestTransport(receiveData: update)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .balanced)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 2)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            0, 0, 248, 255,
            0, 248, 0, 255,
        ])
        XCTAssertEqual(transport.sentMessages[1], StandardRFBMessages.setEncodings(for: .high))
        XCTAssertEqual(transport.sentMessages[3], StandardRFBMessages.setEncodings(for: .balanced))
        XCTAssertEqual(transport.sentMessages.map(\.first), [0, 2, 3, 2, 3, 9, 3])
    }

    func testChangesQualityWithOrderedEncodingsAndFullRefresh() async throws {
        let transport = StandardRFBTestTransport(receiveData: Data())
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)

        try await stream.setQuality(.medium)

        XCTAssertEqual(stream.currentQuality, .medium)
        XCTAssertEqual(transport.sentMessages, [
            StandardRFBMessages.setEncodings(for: .medium),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
        ])
    }

    func testImmediateQualityChangeFollowsInitialConfiguration() async throws {
        let transport = StandardRFBTestTransport(receiveData: Data())
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)

        stream.start()
        try await stream.setQuality(.medium)
        stream.close()

        XCTAssertEqual(transport.sentMessages, [
            StandardRFBMessages.setPixelFormat(.standard),
            StandardRFBMessages.setEncodings(for: .high),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
            StandardRFBMessages.setEncodings(for: .medium),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
        ])
    }

    func testLiveQualityChangeWaitsForConfirmedReplacementCoverage() async throws {
        let transport = ControlledStandardRFBTransport(receiveData: Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
            0x10, 0, 0, 0,
            0x20, 0, 0, 0,
        ]))
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)
        stream.start()
        try await waitUntil { stream.decodedFrameCount == 1 }

        try await stream.setQuality(.medium)
        var receiveCount = transport.successfulReceiveCount
        transport.append(Self.rawRectangleUpdate(x: 0, blue: 0x30))
        try await waitUntil { transport.successfulReceiveCount >= receiveCount + 4 }
        XCTAssertEqual(stream.decodedFrameCount, 1)

        receiveCount = transport.successfulReceiveCount
        transport.append(Self.rawRectangleUpdate(x: 1, blue: 0x40))
        try await waitUntil { transport.successfulReceiveCount >= receiveCount + 4 }
        XCTAssertEqual(stream.decodedFrameCount, 1)

        receiveCount = transport.successfulReceiveCount
        transport.append(Self.rawRectangleUpdate(x: 0, blue: 0x50))
        try await waitUntil { transport.successfulReceiveCount >= receiveCount + 4 }
        XCTAssertEqual(stream.decodedFrameCount, 1)

        transport.append(Self.rawRectangleUpdate(x: 1, blue: 0x60))
        try await waitUntil { stream.decodedFrameCount == 2 }

        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            0x50, 0, 0, 0xff,
            0x60, 0, 0, 0xff,
        ])
        stream.close()
        transport.cancel()
    }

    func testMediumConfirmsInitialRefreshBeforePublishing() async throws {
        var updates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe9,
            0, 0, 0, 9,
            120, 156, 98, 0, 0, 0, 0, 255, 255,
        ])
        updates.append(contentsOf: [
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe9,
            0, 0, 0, 7,
            226, 7, 0, 0, 0, 255, 255,
        ])
        let transport = StandardRFBTestTransport(receiveData: updates)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .medium)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 1)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer), [
            0, 0, 0, 255,
            255, 255, 255, 255,
        ])
        XCTAssertEqual(transport.sentMessages[1], StandardRFBMessages.setEncodings(for: .medium))
        XCTAssertEqual(transport.sentMessages.map(\.first), [0, 2, 3, 3, 9])
    }

    func testAppliesOverlappingCopyRectangleFromPreviousFramebuffer() async throws {
        var updates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 3, 0, 1,
            0, 0, 0, 0,
            0x10, 0, 0, 0,
            0x20, 0, 0, 0,
            0x30, 0, 0, 0,
        ])
        updates.append(contentsOf: [
            0, 0, 0, 1,
            0, 1, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 1,
            0, 0, 0, 0,
        ])
        let transport = StandardRFBTestTransport(receiveData: updates)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 3,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.decodedFrameCount < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer, count: 12), [
            0x10, 0, 0, 0xff,
            0x10, 0, 0, 0xff,
            0x20, 0, 0, 0xff,
        ])
    }

    func testDisplayDrivenPublicationCoalescesAndRetainsFinalFramebuffer() async throws {
        let publicationScheduler = ManualPublicationScheduler()
        let updates = [UInt8(0x10), 0x20, 0x30].reduce(into: Data()) { data, blue in
            data.append(contentsOf: [
                0, 0, 0, 1,
                0, 0, 0, 0, 0, 1, 0, 1,
                0, 0, 0, 0,
                blue, 0, 0, 0,
            ])
        }
        let transport = StandardRFBTestTransport(receiveData: updates)
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(
            session: session,
            quality: .high,
            schedulePublication: publicationScheduler.schedule
        )
        session.install(videoStream: stream)
        stream.setDisplayDrivenFrameRequestsEnabled(true)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await MainActor.run(body: {
            if case .failed = stream.state { return false }
            return true
        }), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(stream.decodedFrameCount, 0)
        XCTAssertEqual(publicationScheduler.pendingCount, 1)
        stream.requestFrameForDisplay()
        XCTAssertEqual(stream.decodedFrameCount, 0)
        XCTAssertEqual(publicationScheduler.pendingCount, 1)
        publicationScheduler.runNext()

        XCTAssertEqual(stream.decodedFrameCount, 1)
        let pixelBuffer = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: pixelBuffer, count: 4), [0x30, 0, 0, 0xff])
        stream.close()
    }

    func testDesktopSizeRequestsFullRefreshWithoutPublishingBlackFrame() async throws {
        let transport = StandardRFBTestTransport(receiveData: Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 4, 0, 3,
            0xff, 0xff, 0xff, 0x21,
        ]))
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while transport.sentMessages.count < 5, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.close()

        XCTAssertEqual(stream.decodedFrameCount, 0)
        XCTAssertNil(stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex))
        XCTAssertEqual(transport.sentMessages.suffix(2).map(\.first), [3, 9])
        XCTAssertEqual(transport.sentMessages.dropLast().last?.prefix(2), Data([3, 0]))
    }

    func testRejectsHextileRectangleOutsideFramebuffer() async throws {
        let transport = StandardRFBTestTransport(receiveData: Data([
            0, 0, 0, 1,
            0, 1, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 5,
            1,
            1, 2, 3, 0, 4, 5, 6, 0,
        ]))
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.state == .preparing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case .failed = stream.state else {
            return XCTFail("Expected an invalid rectangle failure")
        }
        XCTAssertEqual(stream.decodedFrameCount, 0)
        XCTAssertNil(stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex))
        XCTAssertEqual(transport.receivedLengths, [1, 3, 12])
        stream.close()
    }

    func testRejectsRawRectangleOutsideFramebufferBeforeReadingPayload() async throws {
        let transport = StandardRFBTestTransport(receiveData: Data([
            0, 0, 0, 1,
            0, 1, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
        ]))
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)

        stream.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while stream.state == .preparing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case .failed = stream.state else {
            return XCTFail("Expected an invalid rectangle failure")
        }
        XCTAssertEqual(transport.receivedLengths, [1, 3, 12])
        stream.close()
    }

    private static let rawFramebufferUpdate = Data([
        0, 0, 0, 1,
        0, 0, 0, 0, 0, 2, 0, 1,
        0, 0, 0, 0,
        0x33, 0x22, 0x11, 0,
        0x66, 0x55, 0x44, 0,
    ])

    private static func rawRectangleUpdate(x: UInt16, blue: UInt8) -> Data {
        Data([
            0, 0, 0, 1,
            UInt8(x >> 8), UInt8(truncatingIfNeeded: x),
            0, 0, 0, 1, 0, 1,
            0, 0, 0, 0,
            blue, 0, 0, 0,
        ])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }

    private static func bytes(from pixelBuffer: CVPixelBuffer, count: Int = 8) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        return Array(UnsafeRawBufferPointer(start: address, count: count))
    }
}

private final class ManualPublicationScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work = [@Sendable () -> Void]()

    var pendingCount: Int {
        lock.withStandardTestLock { work.count }
    }

    func schedule(_ operation: @escaping @Sendable () -> Void) {
        lock.withStandardTestLock { work.append(operation) }
    }

    func runNext() {
        let operation = lock.withStandardTestLock { work.isEmpty ? nil : work.removeFirst() }
        operation?()
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

private final class StandardRFBTestTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveData: Data
    private var sent = [Data]()
    private var received = [Int]()

    init(receiveData: Data) {
        self.receiveData = receiveData
    }

    var sentMessages: [Data] {
        lock.withStandardTestLock { sent }
    }

    var receivedLengths: [Int] {
        lock.withStandardTestLock { received }
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        lock.withStandardTestLock { sent.append(data) }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try lock.withStandardTestLock {
            received.append(length)
            guard length >= 0, receiveData.count >= length else {
                throw RFBNetworkError.connectionClosed
            }
            let result = receiveData.prefix(length)
            receiveData.removeFirst(length)
            return Data(result)
        }
    }

    func cancel() { }
}

private final class ControlledStandardRFBTransport: RFBTransport, @unchecked Sendable {
    private struct PendingRead {
        let length: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var receiveData: Data
    private var sent = [Data]()
    private var pendingRead: PendingRead?
    private var receiveCount = 0
    private var isCancelled = false

    init(receiveData: Data) {
        self.receiveData = receiveData
    }

    var successfulReceiveCount: Int {
        lock.withStandardTestLock { receiveCount }
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        lock.withStandardTestLock { sent.append(data) }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withStandardTestLock { () -> Result<Data, Error>? in
                guard !isCancelled else {
                    return .failure(RFBNetworkError.connectionClosed)
                }
                guard receiveData.count >= length else {
                    precondition(pendingRead == nil)
                    pendingRead = PendingRead(length: length, continuation: continuation)
                    return nil
                }
                let data = Data(receiveData.prefix(length))
                receiveData.removeFirst(length)
                receiveCount += 1
                return .success(data)
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func append(_ data: Data) {
        let delivery = lock.withStandardTestLock { () -> (PendingRead, Data)? in
            receiveData.append(data)
            guard let pendingRead, receiveData.count >= pendingRead.length else { return nil }
            let result = Data(receiveData.prefix(pendingRead.length))
            receiveData.removeFirst(pendingRead.length)
            self.pendingRead = nil
            receiveCount += 1
            return (pendingRead, result)
        }
        if let (pendingRead, result) = delivery {
            pendingRead.continuation.resume(returning: result)
        }
    }

    func cancel() {
        let pending = lock.withStandardTestLock { () -> PendingRead? in
            isCancelled = true
            defer { pendingRead = nil }
            return pendingRead
        }
        pending?.continuation.resume(throwing: RFBNetworkError.connectionClosed)
    }
}

private extension NSLock {
    func withStandardTestLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
