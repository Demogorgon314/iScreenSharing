import AVFAudio
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaKeys
import struct ScreenSharingProtocol.AppleMediaPorts
import XCTest
@testable import iScreenSharing

final class AppleAudioStreamTests: XCTestCase {
    func testRecognizesOnlyAppleAudioRTPPayload() {
        var audio = Data(repeating: 0, count: 12)
        audio[0] = 0x80
        audio[1] = 101
        XCTAssertTrue(AppleAudioStream.isAudioRTP(audio))

        audio[1] = 72
        XCTAssertFalse(AppleAudioStream.isAudioRTP(audio))
        audio[0] = 0
        audio[1] = 101
        XCTAssertFalse(AppleAudioStream.isAudioRTP(audio))
    }

    @MainActor
    func testMuteStateIsIsolatedToEachSession() throws {
        let firstPlayer = AudioStreamRecordingPlayer()
        let secondPlayer = AudioStreamRecordingPlayer()
        let first = try AppleAudioStream(
            receiver: AudioStreamReceiver(),
            negotiation: mediaNegotiation,
            player: firstPlayer
        )
        let second = try AppleAudioStream(
            receiver: AudioStreamReceiver(),
            negotiation: mediaNegotiation,
            player: secondPlayer
        )
        defer {
            first.close()
            second.close()
        }

        XCTAssertFalse(first.isMuted)
        XCTAssertFalse(second.isMuted)
        XCTAssertEqual(firstPlayer.muteValues, [false])
        XCTAssertEqual(secondPlayer.muteValues, [false])

        first.toggleMute()

        XCTAssertTrue(first.isMuted)
        XCTAssertFalse(second.isMuted)
        XCTAssertEqual(firstPlayer.muteValues, [false, true])
        XCTAssertEqual(secondPlayer.muteValues, [false])
    }

    private var mediaNegotiation: AppleMediaNegotiationResult {
        AppleMediaNegotiationResult(
            keys: AppleMediaKeys(
                audioViewer: Data(repeating: 1, count: 46),
                audioServer: Data(repeating: 2, count: 46),
                videoViewer: Data(repeating: 3, count: 46),
                videoServer: Data(repeating: 4, count: 46)
            ),
            canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            videoSynchronizationSource: 0x1122_3344,
            configuration: Data(),
            pendingMessages: []
        )
    }
}

private final class AudioStreamRecordingPlayer: AppleAudioPlaying {
    private(set) var muteValues = [Bool]()

    func play(_ buffer: AVAudioPCMBuffer) { }
    func setMuted(_ muted: Bool) { muteValues.append(muted) }
    func close() { }
}

private final class AudioStreamReceiver: AppleMediaReceiving, @unchecked Sendable {
    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws { }

    func stopVideoDelivery(mediaStreamIndex: Int) { }
    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? { nil }
    func drainControlPackets() -> [Data] { [] }
    func sendControl(_ datagram: Data) throws { }
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws { }
    func configureRemotePorts(_ ports: AppleMediaPorts) throws { }
    func stopPunching() { }
    func close() { }
}
