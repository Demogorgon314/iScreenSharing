import AVFAudio
import XCTest
@testable import iShareScreen

final class RFBAuthenticationIntegrationTests: XCTestCase {
    func testAuthenticatesAgainstConfiguredMac() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ISHARESCREEN_TEST_HOST"],
              let username = environment["ISHARESCREEN_TEST_USERNAME"],
              let password = environment["ISHARESCREEN_TEST_PASSWORD"] else {
            throw XCTSkip("Set ISHARESCREEN_TEST_HOST, _USERNAME, and _PASSWORD to run the LAN integration test.")
        }

        let session = try await RFBAuthenticationService().connect(
            to: ConnectionEndpoint(host),
            credentials: ScreenSharingCredentials(username: username, password: password)
        )
        defer { session.close() }

        XCTAssertEqual(session.serverVersion, RFBVersion(major: 3, minor: 889))
        XCTAssertEqual(session.masterKey.count, 16)
        XCTAssertTrue(session.securityTypes.contains(.appleRSA))
        XCTAssertGreaterThan(session.serverInfo.width, 0)
        XCTAssertGreaterThan(session.serverInfo.height, 0)

        let recordLayer = try await AppleControlChannelNegotiator().enableEncryption(for: session)
        XCTAssertEqual(recordLayer.contentKey.count, 16)
        XCTAssertEqual(session.recordLayer?.contentKey, recordLayer.contentKey)
        XCTAssertGreaterThanOrEqual(session.rekeyGeneration ?? 0, 1)

        let media = try await AppleMediaNegotiator().negotiate(session)
        XCTAssertTrue(media.canvas.isUsable)
        XCTAssertGreaterThan(media.canvas.width, 0)
        XCTAssertGreaterThan(media.canvas.height, 0)
        XCTAssertGreaterThan(media.canvas.tileCount, 0)
        XCTAssertEqual(session.mediaNegotiation, media)
        let input = AppleInputController(session: session, canvas: media.canvas)
        let clipboard = await MainActor.run { IntegrationClipboardReceiver() }
        let controlMessages = AppleControlMessageService(
            session: session,
            input: input,
            clipboard: clipboard,
            pendingMessages: media.pendingMessages
        )
        controlMessages.start()
        defer { controlMessages.close() }
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

        let countBeforeInput = await input.sentEventCount
        await input.pointer(buttons: 0, x: media.canvas.width / 2, y: media.canvas.height / 2)
        await input.key(isDown: true, symbol: 0xffe1)
        await input.key(isDown: false, symbol: 0xffe1)
        let sentEventCount = await input.sentEventCount
        XCTAssertGreaterThanOrEqual(sentEventCount, countBeforeInput + 3)
    }
}

@MainActor
private final class IntegrationClipboardReceiver: AppleClipboardReceiving {
    func receive(_ text: String) { }
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
