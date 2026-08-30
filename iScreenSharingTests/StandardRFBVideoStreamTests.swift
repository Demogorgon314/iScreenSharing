import CoreVideo
import Foundation
import enum ScreenSharingProtocol.AppleRFBMessages
import enum ScreenSharingProtocol.StandardRFBMessages
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

final class StandardRFBVideoStreamTests: XCTestCase {
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
        let bootstrapUpdate = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
        ])
        var reducedColorUpdates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe8,
            0, 0, 0, 9,
            120, 156, 98, 0, 0, 0, 0, 255, 255,
        ])
        reducedColorUpdates.append(contentsOf: [
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xe8,
            0, 0, 0, 7,
            106, 0, 0, 0, 0, 255, 255,
        ])
        let transport = ControlledStandardRFBTransport(receiveData: bootstrapUpdate)
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
        try await waitUntil { stream.decodedFrameCount == 1 }
        let bootstrapFrame = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: bootstrapFrame), [
            1, 2, 3, 255,
            4, 5, 6, 255,
        ])
        transport.append(reducedColorUpdates)
        try await waitUntil { stream.decodedFrameCount == 2 }
        stream.close()
        transport.cancel()

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
        let bootstrapUpdate = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
        ])
        var reducedColorUpdates = Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xea,
            0, 0, 0, 12,
            120, 156, 98, 96, 96, 96, 0, 0, 0, 0, 255, 255,
        ])
        reducedColorUpdates.append(contentsOf: [
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 3, 0xea,
            0, 0, 0, 10,
            170, 97, 96, 126, 0, 0, 0, 0, 255, 255,
        ])
        let transport = ControlledStandardRFBTransport(receiveData: bootstrapUpdate)
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
        try await waitUntil { stream.decodedFrameCount == 1 }
        let bootstrapFrame = try XCTUnwrap(
            stream.frames.frame(at: AppleVideoFrameStore.fullCanvasIndex)
        )
        XCTAssertEqual(Self.bytes(from: bootstrapFrame), [
            1, 2, 3, 255,
            4, 5, 6, 255,
        ])
        transport.append(reducedColorUpdates)
        try await waitUntil { stream.decodedFrameCount == 2 }
        stream.close()
        transport.cancel()

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

    var sentMessages: [Data] {
        lock.withStandardTestLock { sent }
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
