import AVFAudio
import CoreVideo
import enum ScreenSharingProtocol.AppleRFBMessages
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleClipboardArchive
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import XCTest
@testable import iScreenSharing

final class RFBAuthenticationIntegrationTests: XCTestCase {
    func testAuthenticatesAgainstConfiguredMac() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ISHARESCREEN_TEST_HOST"],
              let username = environment["ISHARESCREEN_TEST_USERNAME"],
              let password = environment["ISHARESCREEN_TEST_PASSWORD"] else {
            throw XCTSkip("Set ISHARESCREEN_TEST_HOST, _USERNAME, and _PASSWORD to run the LAN integration test.")
        }
        let virtualDisplayCount: VirtualDisplayCount = environment["ISHARESCREEN_TEST_DISPLAY_COUNT"] == "2"
            ? .two
            : .one

        let session = try await RFBAuthenticationService().connect(
            to: ConnectionEndpoint(host),
            credentials: ScreenSharingCredentials(username: username, password: password),
            sharingType: .highPerformance
        )
        defer { session.close() }

        XCTAssertEqual(session.masterKey.count, 16)
        XCTAssertGreaterThan(session.serverInfo.width, 0)
        XCTAssertGreaterThan(session.serverInfo.height, 0)

        let recordLayer = try await AppleControlChannelNegotiator().enableEncryption(
            for: session,
            displaySizes: Array(
                repeating: AppleDynamicResolutionSize(width: 1440, height: 900),
                count: virtualDisplayCount.rawValue
            )
        )
        XCTAssertEqual(recordLayer.contentKey.count, 16)
        XCTAssertEqual(session.recordLayer?.contentKey, recordLayer.contentKey)
        let media = try await AppleMediaNegotiator().negotiate(
            session,
            displayCount: virtualDisplayCount.rawValue
        )
        XCTAssertTrue(media.canvas.isUsable)
        XCTAssertGreaterThan(media.canvas.width, 0)
        XCTAssertGreaterThan(media.canvas.height, 0)
        XCTAssertGreaterThan(media.canvas.tileCount, 0)
        let input = AppleInputController(session: session, canvas: media.canvas)
        let clipboard = await MainActor.run { IntegrationClipboardReceiver() }
        let receiver = try XCTUnwrap(session.mediaReceiver)
        let audioPlayer = IntegrationAudioPlayer()
        let audioStream = try AppleAudioStream(
            receiver: receiver,
            negotiation: media,
            player: audioPlayer
        )
        audioStream.start()
        defer { audioStream.close() }
        let stream = try AppleVideoStream(receiver: receiver, negotiation: media)
        session.install(videoStream: stream)
        stream.start()
        let dynamicResolution = AppleDynamicResolutionController(
            initialCanvas: media.canvas,
            mediaConfiguration: media.configuration,
            sendMessage: { [weak session] message in
                guard let session else { return }
                try await session.sendEncrypted(message)
            },
            applyCanvas: { [weak stream, weak input] canvas in
                await stream?.updateCanvas(canvas)
                await input?.update(canvas: canvas)
            },
            prepareMediaRestart: { [weak stream] in
                await stream?.prepareForMediaRestart()
            }
        )
        let cursorStore = AppleCursorStore()
        let controlMessages = AppleControlMessageService(
            session: session,
            input: input,
            clipboard: clipboard,
            pendingMessages: media.pendingMessages,
            receiveDisplayLayout: { layout in
                try? await dynamicResolution.receive(layout)
            },
            receiveMediaCanvas: { canvas in
                await dynamicResolution.receiveMediaCanvas(canvas)
            },
            receiveCursorUpdate: { update in
                cursorStore.apply(update)
            }
        )
        controlMessages.start()
        defer { controlMessages.close() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while clock.now < deadline {
            let allTilesHaveFrames = (0..<media.canvas.tileCount).allSatisfy {
                stream.frames.frame(at: $0) != nil
            }
            if allTilesHaveFrames, stream.state == .streaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue((0..<media.canvas.tileCount).allSatisfy { stream.frames.frame(at: $0) != nil })
        XCTAssertGreaterThanOrEqual(stream.decodedFrameCount, media.canvas.tileCount)
        XCTAssertEqual(stream.state, .streaming)
        if environment["ISHARESCREEN_TEST_EXPECT_VISIBLE_FRAME"] == "1" {
            let ranges = (0..<media.canvas.tileCount).compactMap {
                stream.frames.frame(at: $0).flatMap(lumaRange)
            }
            XCTAssertTrue(
                ranges.contains { Int($0.upperBound) - Int($0.lowerBound) >= 8 },
                "Decoded HEVC tiles have no visible luminance contrast: \(ranges)"
            )
        }

        let audioDeadline = clock.now.advanced(by: .seconds(3))
        while audioStream.decodedPacketCount == 0, clock.now < audioDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(audioStream.receivedPacketCount, 0)
        XCTAssertGreaterThan(audioStream.decodedPacketCount, 0)
        XCTAssertGreaterThan(audioPlayer.playedBufferCount, 0)

        let controlDeadline = clock.now.advanced(by: .seconds(3))
        while controlMessages.receivedMessageCount == 0, clock.now < controlDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(controlMessages.receivedMessageCount, 0)

        let cursorDeadline = clock.now.advanced(by: .seconds(3))
        while cursorStore.receivedUpdateCount == 0, clock.now < cursorDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(cursorStore.receivedUpdateCount, 0)

        let initialCanvas = stream.canvas
        let frameCountBeforeResize = stream.decodedFrameCount
        let requestedSize = initialCanvas.width == 1920 && initialCanvas.height == 1080
            ? AppleDynamicResolutionSize(width: 1440, height: 900)
            : AppleDynamicResolutionSize(width: 960, height: 540)
        try await dynamicResolution.request(width: requestedSize.width, height: requestedSize.height)
        let resizeDeadline = clock.now.advanced(by: .seconds(10))
        while clock.now < resizeDeadline {
            let resizedCanvas = stream.canvas
            let allTilesHaveFrames = (0..<resizedCanvas.tileCount).allSatisfy {
                stream.frames.frame(at: $0) != nil
            }
            if resizedCanvas != initialCanvas {
                XCTAssertEqual(stream.state, .streaming)
                XCTAssertTrue(
                    allTilesHaveFrames,
                    "A hot resolution change must retain the last complete frame until replacement frames arrive."
                )
            }
            if resizedCanvas != initialCanvas,
               allTilesHaveFrames,
               stream.state == .streaming,
               stream.decodedFrameCount > frameCountBeforeResize {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(stream.canvas, initialCanvas)
        XCTAssertEqual(stream.state, .streaming)
        XCTAssertTrue((0..<stream.canvas.tileCount).allSatisfy { stream.frames.frame(at: $0) != nil })
        XCTAssertGreaterThan(
            stream.decodedFrameCount,
            frameCountBeforeResize,
            "The restarted media generation must replace the retained frame."
        )

        try await session.sendEncrypted(AppleRFBMessages.controlMode(observing: true))
        try await Task.sleep(for: .milliseconds(50))
        try await session.sendEncrypted(AppleRFBMessages.controlMode(observing: false))

        let countBeforeInput = await input.sentEventCount
        await input.pointer(buttons: 0, x: stream.canvas.width / 2, y: stream.canvas.height / 2)
        await input.key(isDown: true, symbol: 0xffe1)
        await input.key(isDown: false, symbol: 0xffe1)
        let sentEventCount = await input.sentEventCount
        XCTAssertGreaterThanOrEqual(sentEventCount, countBeforeInput + 3)
    }
}

private func lumaRange(of pixelBuffer: CVPixelBuffer) -> ClosedRange<UInt8>? {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
          CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard width > 0, height > 0 else { return nil }

    let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let horizontalStride = max(1, width / 128)
    let verticalStride = max(1, height / 128)
    var minimum = UInt8.max
    var maximum = UInt8.min
    for y in stride(from: 0, to: height, by: verticalStride) {
        for x in stride(from: 0, to: width, by: horizontalStride) {
            let value = bytes[y * bytesPerRow + x]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
    }
    return minimum...maximum
}

@MainActor
private final class IntegrationClipboardReceiver: AppleClipboardReceiving {
    var allowsRemoteSynchronization: Bool { true }
    func localArchive() -> AppleClipboardArchive? { nil }
    func archiveForRemoteRequest() -> AppleClipboardArchive? { nil }
    func remoteRequestDidFinish() { }
    func remotePasteboardDidChange() { }
    func receive(_ archive: AppleClipboardArchive) { }
    func synchronizationLease() -> UInt64? { 0 }
    func isSynchronizationLeaseValid(_ lease: UInt64) -> Bool { lease == 0 }
    func receiveIfEligible(_ archive: AppleClipboardArchive, lease: UInt64) -> Bool {
        lease == 0
    }
}

private final class IntegrationAudioPlayer: AppleAudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var playedBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func setMuted(_ muted: Bool) { }
    func close() { }
}
