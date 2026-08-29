import CoreVideo
import XCTest
@testable import iScreenSharing

final class StandardRFBProtocolTests: XCTestCase {
    func testBuildsClientInitializationAndHighQualityPixelFormat() {
        XCTAssertEqual(StandardRFBMessages.clientInit, Data([1]))
        XCTAssertEqual(
            StandardRFBMessages.setPixelFormat(.forQuality(.high)),
            Data([
                0, 0, 0, 0,
                32, 24, 0, 1,
                0, 255, 0, 255, 0, 255,
                16, 8, 0, 0, 0, 0,
            ])
        )
    }

    func testCompressedMonochromeAndGrayscaleKeepServerCompatible32BitPixelFormat() {
        let expected = Data([
            0, 0, 0, 0,
            32, 24, 0, 1,
            0, 255, 0, 255, 0, 255,
            16, 8, 0, 0, 0, 0,
        ])
        XCTAssertEqual(StandardRFBMessages.setPixelFormat(.forQuality(.medium)), expected)
        XCTAssertEqual(StandardRFBMessages.setPixelFormat(.forQuality(.lowBandwidth)), expected)
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
            pixelFormat: .forQuality(.high),
            read: { try input.read($0) }
        )

        XCTAssertEqual(Array(output[0..<4]), [0x10, 0x20, 0x30, 0xff])
        XCTAssertEqual(Array(output[20..<24]), [0x60, 0x50, 0x40, 0xff])
        XCTAssertEqual(Array(output[24..<28]), [0x60, 0x50, 0x40, 0xff])
        XCTAssertEqual(Array(output[44..<48]), [0x10, 0x20, 0x30, 0xff])
    }

    func testDecodesAllQualityFormatsToBGRA() throws {
        XCTAssertEqual(
            try StandardRFBPixelFormat.forQuality(.high).decodeBGRA(
                Data([0x33, 0x22, 0x11, 0]),
                pixelCount: 1
            ),
            Data([0x33, 0x22, 0x11, 0xff])
        )
        XCTAssertEqual(
            try StandardRFBPixelFormat.forQuality(.balanced).decodeBGRA(
                Data([0x00, 0xf8]),
                pixelCount: 1
            ),
            Data([0, 0, 255, 255])
        )
        XCTAssertEqual(
            try StandardRFBPixelFormat.forQuality(.balanced).decodeBGRA(
                Data([0x10, 0x84]),
                pixelCount: 1
            ),
            Data([132, 130, 132, 255])
        )
        XCTAssertThrowsError(
            try StandardRFBPixelFormat.forQuality(.balanced).decodeBGRA(
                Data([0]),
                pixelCount: 1
            )
        )
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

    func testDecodesRGB565DirectlyIntoStridedFramebufferRegion() throws {
        var framebuffer = Data(repeating: 0xaa, count: 32)
        try framebuffer.withUnsafeMutableBytes { destination in
            try StandardRFBPixelFormat.forQuality(.balanced).decodeBGRA(
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

    func testReceivesLowBandwidthHalftoneRectangle() async throws {
        let update = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe8,
            0, 0, 0, 9,
            120, 156, 106, 0, 0, 0, 0, 255, 255,
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
        let stream = try StandardRFBVideoStream(session: session, quality: .lowBandwidth)
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
            255, 255, 255, 255,
            0, 0, 0, 255,
        ])
        XCTAssertEqual(transport.sentMessages[1], StandardRFBMessages.setEncodings(for: .lowBandwidth))
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
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
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

        XCTAssertEqual(stream.decodedFrameCount, 1)
        stream.requestFrameForDisplay()

        XCTAssertEqual(stream.decodedFrameCount, 2)
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

    private static let rawFramebufferUpdate = Data([
        0, 0, 0, 1,
        0, 0, 0, 0, 0, 2, 0, 1,
        0, 0, 0, 0,
        0x33, 0x22, 0x11, 0,
        0x66, 0x55, 0x44, 0,
    ])

    private static func bytes(from pixelBuffer: CVPixelBuffer, count: Int = 8) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        return Array(UnsafeRawBufferPointer(start: address, count: count))
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

    init(receiveData: Data) {
        self.receiveData = receiveData
    }

    var sentMessages: [Data] {
        lock.withStandardTestLock { sent }
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        lock.withStandardTestLock { sent.append(data) }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try lock.withStandardTestLock {
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

private extension NSLock {
    func withStandardTestLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
