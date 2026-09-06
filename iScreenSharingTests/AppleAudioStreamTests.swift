import AVFAudio
import Combine
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaKeys
import struct ScreenSharingProtocol.AppleMediaPorts
import XCTest
@testable import iScreenSharing

@MainActor
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

    func testMuteDuringPreparationIsAppliedBeforeDeliveryAndIsIsolatedToSession() async throws {
        let entered = expectation(description: "First session preparing")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstDelivery = expectation(description: "First session delivery")
        let secondDelivery = expectation(description: "Second session delivery")
        let firstPlayer = AudioStreamRecordingPlayer()
        let secondPlayer = AudioStreamRecordingPlayer()
        let first = try AppleAudioStream(
            receiver: AudioStreamReceiver(onFirstDrain: {
                XCTAssertEqual(firstPlayer.muteValues.first, true)
                firstDelivery.fulfill()
            }),
            negotiation: audioStreamTestNegotiation,
            playbackFactory: {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return .init(decoder: AudioStreamDecoder(), player: firstPlayer)
            }
        )
        let second = try AppleAudioStream(
            receiver: AudioStreamReceiver(onFirstDrain: { secondDelivery.fulfill() }),
            negotiation: audioStreamTestNegotiation,
            playbackFactory: { .init(decoder: AudioStreamDecoder(), player: secondPlayer) }
        )
        defer {
            first.close()
            second.close()
        }

        first.start()
        await fulfillment(of: [entered], timeout: 2)
        first.start() // Preparation, not just the receive timer, is one-shot.
        first.toggleMute()
        second.start()
        await fulfillment(of: [secondDelivery], timeout: 2)
        XCTAssertTrue(first.isMuted)
        XCTAssertTrue(first.isAvailable)
        XCTAssertFalse(second.isMuted)
        XCTAssertTrue(firstPlayer.muteValues.isEmpty)
        XCTAssertEqual(secondPlayer.muteValues, [false])
        release.signal()
        await fulfillment(of: [firstDelivery], timeout: 2)
        XCTAssertTrue(firstPlayer.muteValues.allSatisfy { $0 })
    }

    func testCloseDuringPreparationDisposesLatePlaybackWithoutDeliveryOrReadyEvent() async throws {
        let entered = expectation(description: "Preparing")
        let closed = expectation(description: "Late player disposed")
        let unavailable = expectation(description: "Audio disabled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let player = AudioStreamRecordingPlayer(onClose: { closed.fulfill() })
        let receiver = AudioStreamReceiver()
        let timings = StartupTimingRecorder()
        let audio = try AppleAudioStream(
            receiver: receiver,
            negotiation: audioStreamTestNegotiation,
            connectionTiming: timings.makeTrace(),
            playbackFactory: {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return .init(decoder: AudioStreamDecoder(), player: player)
            }
        )
        let subscription = audio.$isAvailable.filter { !$0 }.sink { _ in unavailable.fulfill() }
        defer { subscription.cancel() }
        audio.start()
        await fulfillment(of: [entered], timeout: 2)
        audio.close()
        audio.close()
        audio.start()
        await fulfillment(of: [unavailable], timeout: 2)
        release.signal()
        await fulfillment(of: [closed], timeout: 2)

        XCTAssertEqual(player.closeCount, 1)
        XCTAssertEqual(receiver.drainCount, 0)
        XCTAssertNil(timings.entry(.audioReady))
        XCTAssertNil(timings.entry(.audioUnavailable))
    }

    func testPreparationFailureDisablesAudioWithoutStartingDelivery() async throws {
        let unavailable = expectation(description: "Failed audio disabled")
        let receiver = AudioStreamReceiver()
        let timings = StartupTimingRecorder()
        let audio = try AppleAudioStream(
            receiver: receiver,
            negotiation: audioStreamTestNegotiation,
            connectionTiming: timings.makeTrace(),
            playbackFactory: { throw AppleAACELDDecoderError.converterCreationFailed }
        )
        defer { audio.close() }
        let subscription = audio.$isAvailable.filter { !$0 }.sink { _ in unavailable.fulfill() }
        defer { subscription.cancel() }
        audio.start()
        await fulfillment(of: [unavailable], timeout: 2)
        audio.toggleMute()

        XCTAssertFalse(audio.isAvailable)
        XCTAssertFalse(audio.isMuted)
        XCTAssertEqual(receiver.drainCount, 0)
        XCTAssertNotNil(timings.entry(.audioUnavailable))
        XCTAssertNil(timings.entry(.audioReady))
    }

    func testClosingRunningPlaybackDisposesItOnce() async throws {
        let delivery = expectation(description: "Running")
        let closed = expectation(description: "Player disposed")
        let player = AudioStreamRecordingPlayer(onClose: { closed.fulfill() })
        let receiver = AudioStreamReceiver(onFirstDrain: { delivery.fulfill() })
        let audio = try AppleAudioStream(
            receiver: receiver,
            negotiation: audioStreamTestNegotiation,
            playbackFactory: { .init(decoder: AudioStreamDecoder(), player: player) }
        )
        audio.start()
        await fulfillment(of: [delivery], timeout: 2)
        audio.close()
        audio.close()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(player.closeCount, 1)
    }

    func testRunningPlaybackAppliesMuteChangesOnItsAudioQueue() async throws {
        let delivery = expectation(description: "Running")
        let muted = expectation(description: "Player muted")
        let unmuted = expectation(description: "Player unmuted")
        let player = AudioStreamRecordingPlayer(onMute: { values in
            XCTAssertFalse(Thread.isMainThread)
            if values == [false, true] { muted.fulfill() }
            if values == [false, true, false] { unmuted.fulfill() }
        })
        let audio = try AppleAudioStream(
            receiver: AudioStreamReceiver(onFirstDrain: { delivery.fulfill() }),
            negotiation: audioStreamTestNegotiation,
            playbackFactory: { .init(decoder: AudioStreamDecoder(), player: player) }
        )
        defer { audio.close() }
        audio.start()
        await fulfillment(of: [delivery], timeout: 2)
        audio.toggleMute()
        await fulfillment(of: [muted], timeout: 2)
        XCTAssertTrue(audio.isMuted)
        audio.toggleMute()
        await fulfillment(of: [unmuted], timeout: 2)
        XCTAssertFalse(audio.isMuted)
    }

    func testClosedStreamCannotBeginPreparationOrAcceptMuteCommands() async throws {
        let unavailable = expectation(description: "Closed audio disabled")
        let audio = try AppleAudioStream(
            receiver: AudioStreamReceiver(),
            negotiation: audioStreamTestNegotiation,
            playbackFactory: {
                XCTFail("A closed stream must not create playback resources")
                throw AppleAACELDDecoderError.converterCreationFailed
            }
        )
        let subscription = audio.$isAvailable.filter { !$0 }.sink { _ in unavailable.fulfill() }
        defer { subscription.cancel() }
        audio.close()
        audio.start()
        audio.toggleMute()
        await fulfillment(of: [unavailable], timeout: 2)
        XCTAssertFalse(audio.isMuted)
    }

    func testReleasingRunningStreamDisposesPlaybackWithoutExplicitClose() async throws {
        let delivery = expectation(description: "Running")
        let closed = expectation(description: "Player disposed")
        let player = AudioStreamRecordingPlayer(onClose: { closed.fulfill() })
        var audio: AppleAudioStream? = try AppleAudioStream(
            receiver: AudioStreamReceiver(onFirstDrain: { delivery.fulfill() }),
            negotiation: audioStreamTestNegotiation,
            playbackFactory: { .init(decoder: AudioStreamDecoder(), player: player) }
        )
        audio?.start()
        await fulfillment(of: [delivery], timeout: 2)
        audio = nil
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(player.closeCount, 1)
    }
}

var audioStreamTestNegotiation: AppleMediaNegotiationResult {
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

final class AudioStreamDecoder: AppleAudioDecoding {
    func decode(_ accessUnit: Data) throws -> AVAudioPCMBuffer? { nil }
}

final class AudioStreamRecordingPlayer: AppleAudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMuteValues = [Bool]()
    private var recordedCloseCount = 0
    private let onClose: @Sendable () -> Void
    private let onMute: @Sendable ([Bool]) -> Void

    init(
        onClose: @escaping @Sendable () -> Void = {},
        onMute: @escaping @Sendable ([Bool]) -> Void = { _ in }
    ) {
        self.onClose = onClose
        self.onMute = onMute
    }

    var muteValues: [Bool] { lock.withLock { recordedMuteValues } }
    var closeCount: Int { lock.withLock { recordedCloseCount } }

    func play(_ buffer: AVAudioPCMBuffer) { }
    func setMuted(_ muted: Bool) {
        let values = lock.withLock {
            recordedMuteValues.append(muted)
            return recordedMuteValues
        }
        onMute(values)
    }
    func close() {
        lock.withLock { recordedCloseCount += 1 }
        onClose()
    }
}

final class AudioStreamReceiver: AppleMediaReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDrainCount = 0
    private let onFirstDrain: @Sendable () -> Void

    init(onFirstDrain: @escaping @Sendable () -> Void = {}) { self.onFirstDrain = onFirstDrain }

    var drainCount: Int { lock.withLock { recordedDrainCount } }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws { }

    func stopVideoDelivery(mediaStreamIndex: Int) { }
    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? { nil }
    func drainControlPackets() -> [Data] {
        let first = lock.withLock {
            recordedDrainCount += 1
            return recordedDrainCount == 1
        }
        if first { onFirstDrain() }
        return []
    }
    func sendControl(_ datagram: Data) throws { }
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws { }
    func configureRemotePorts(_ ports: AppleMediaPorts) throws { }
    func stopPunching() { }
    func close() { }
}
