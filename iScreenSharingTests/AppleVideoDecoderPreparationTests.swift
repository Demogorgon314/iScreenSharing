import CryptoKit
import Foundation
import XCTest
@testable import ScreenSharingProtocol
@testable import iScreenSharing

final class AppleVideoDecoderPreparationTests: XCTestCase {
    private static let canvas = AppleCanvas(width: 8, height: 4, tileCount: 4)

    func testPreparationOverlapsWindowWithoutAdvancingSelectionOrSubmittingFrames() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)

        XCTAssertEqual(harness.probe.attempts, 1)
        XCTAssertEqual(harness.probe.duration(.decoderPreparationReady), 100, accuracy: 0.001)
        XCTAssertNil(harness.probe.entry(.sourcesSelected))
        XCTAssertTrue(harness.probe.decoders[0].orders.isEmpty)

        try await deliver(try packets(sequences: 25..<26), at: 100.299, to: harness)
        XCTAssertNil(harness.probe.entry(.sourcesSelected))
        try await deliver(try packets(sequences: 26..<27), at: 100.301, to: harness)

        XCTAssertEqual(harness.probe.duration(.sourcesSelected), 301, accuracy: 0.001)
        XCTAssertEqual(harness.probe.duration(.decoderReady), 0, accuracy: 0.001)
        XCTAssertEqual(harness.probe.attempts, 1)
        XCTAssertNotNil(harness.probe.entry(.decoderPreparationReused))
        XCTAssertFalse(harness.probe.decoders[0].orders.isEmpty)
    }

    func testPreparedDecoderUsesLaterWinningGroupFromUnchangedObservationWindow() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)
        try await deliver(try packets(sources: 200..<204, sequences: 250..<255), at: 100.2, to: harness)
        try await deliver(try packets(sources: 200..<204, sequences: 255..<256), at: 100.301, to: harness)

        XCTAssertEqual(harness.probe.attempts, 1)
        let orders = harness.probe.decoders[0].orders
        XCTAssertFalse(orders.isEmpty)
        XCTAssertTrue(orders.allSatisfy { $0 >= 1_000 })
    }

    func testInitialModePreparesCorrectDecoderAndWindowReapplicationPreservesIt() async throws {
        for mode in [AppleVideoDecoderMode.videoProcessing, .videoToolboxSynchronized] {
            let harness = try makeHarness(decoderMode: mode)
            defer { harness.stream.close() }
            try await deliverInitialBurst(to: harness)
            XCTAssertEqual(harness.probe.modes, [mode])

            harness.stream.setDecoderMode(mode)
            await harness.stream.updateCanvas(Self.canvas)
            try await deliver(try packets(sequences: 25..<26), at: 100.301, to: harness)

            XCTAssertEqual(harness.probe.attempts, 1)
            XCTAssertFalse(harness.probe.decoders[0].isClosed)
            XCTAssertNotNil(harness.probe.entry(.decoderPreparationReused))
            XCTAssertFalse(harness.probe.decoders[0].orders.isEmpty)
        }
    }

    func testChangedParametersReplacePreparedDecoderBeforeAnySubmission() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)
        try await deliver(try packets(sequences: 25..<26, sequenceParameter: 0xbc), at: 100.2, to: harness)
        XCTAssertEqual(harness.probe.attempts, 1)
        try await deliver(try packets(sequences: 26..<27, sequenceParameter: 0xbc), at: 100.301, to: harness)

        XCTAssertEqual(harness.probe.attempts, 2)
        XCTAssertTrue(harness.probe.decoders[0].isClosed)
        XCTAssertTrue(harness.probe.decoders[0].orders.isEmpty)
        XCTAssertFalse(harness.probe.decoders[1].orders.isEmpty)
        XCTAssertEqual(harness.probe.parameters.last?.sequence, Data([0x42, 1, 0xbc]))
        XCTAssertNil(harness.probe.entry(.decoderPreparationReused))
    }

    func testModeChangeDiscardsPreparedDecoderAndPreservesBufferedUnits() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)
        harness.stream.setDecoderMode(.videoToolboxSynchronized)
        await harness.stream.updateCanvas(Self.canvas)

        XCTAssertTrue(harness.probe.decoders[0].isClosed)
        try await deliver(try packets(sequences: 25..<26), at: 100.301, to: harness)
        XCTAssertEqual(harness.probe.attempts, 2)
        XCTAssertEqual(harness.probe.modes.last, .videoToolboxSynchronized)
        XCTAssertTrue(harness.probe.decoders[1].orders.contains(0))
    }

    func testMediaRestartClosesPreparedDecoderAndDiscardsOldBufferedUnits() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)
        await harness.stream.prepareForMediaRestart()
        XCTAssertTrue(harness.probe.decoders[0].isClosed)

        try await deliver(try packets(sources: 200..<204, sequences: 250..<251), at: 100.2, to: harness)
        XCTAssertEqual(harness.probe.attempts, 2)
        XCTAssertTrue(harness.probe.decoders[0].orders.isEmpty)
        XCTAssertEqual(harness.probe.decoders[1].orders, [1_000, 1_001, 1_002, 1_003])
    }

    func testPreparationWaitsForCompleteParameters() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliver(try packets(sequences: 0..<25, includesParameters: false), at: 100, to: harness)
        XCTAssertEqual(harness.probe.attempts, 0)
        XCTAssertNil(harness.probe.entry(.decoderPreparationStarted))

        try await deliver(try packets(sequences: 25..<26), at: 100.05, to: harness)
        XCTAssertEqual(harness.probe.attempts, 1)
        XCTAssertNil(harness.probe.entry(.sourcesSelected))
    }

    func testChangedTileCountDiscardsIncompatiblePreparedDecoder() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        try await deliverInitialBurst(to: harness)
        let canvas = AppleCanvas(width: 8, height: 4, tileCount: 2)
        await harness.stream.updateCanvas(canvas)
        XCTAssertTrue(harness.probe.decoders[0].isClosed)

        harness.probe.setTime(100.301)
        try await harness.receiver.deliver(
            try packets(sources: 100..<102, sequences: 25..<26), arrivalTime: 100.301
        )
        await harness.stream.updateCanvas(canvas)
        XCTAssertEqual(harness.probe.tileCounts, [4, 2])
        XCTAssertFalse(harness.probe.decoders[1].orders.isEmpty)
        XCTAssertNil(harness.probe.entry(.decoderPreparationReused))
    }

    func testClosingDuringPreparationReleasesDecoderWithoutActivation() async throws {
        let entered = expectation(description: "decoder factory entered")
        let closed = expectation(description: "prepared decoder closed")
        let gate = DispatchSemaphore(value: 0)
        let harness = try makeHarness()
        harness.probe.onCreate = {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
        }
        harness.probe.onClose = { closed.fulfill() }
        defer { harness.stream.close() }

        try await harness.receiver.deliver(try packets(sequences: 0..<25), arrivalTime: harness.probe.now)
        await fulfillment(of: [entered], timeout: 5)
        harness.stream.close()
        gate.signal()
        await fulfillment(of: [closed], timeout: 5)

        XCTAssertNil(harness.probe.entry(.sourcesSelected))
        XCTAssertTrue(harness.probe.decoders[0].orders.isEmpty)
    }

    func testFailedPreparationRetriesOnlyAtActivation() async throws {
        let harness = try makeHarness()
        defer { harness.stream.close() }
        harness.probe.failFirstAttempt = true
        try await deliverInitialBurst(to: harness)
        try await deliver(try packets(sequences: 25..<26), at: 100.2, to: harness)
        XCTAssertEqual(harness.probe.attempts, 1)
        XCTAssertNotNil(harness.probe.entry(.decoderPreparationFailed))
        XCTAssertNil(harness.probe.entry(.decoderPreparationReady))

        try await deliver(try packets(sequences: 26..<27), at: 100.301, to: harness)
        XCTAssertEqual(harness.probe.attempts, 2)
        XCTAssertEqual(harness.probe.duration(.decoderReady), 100, accuracy: 0.001)
        XCTAssertFalse(harness.probe.decoders[0].orders.isEmpty)
    }

    private struct Harness {
        let stream: AppleVideoStream
        let receiver: VideoStreamReceiver
        let probe: PreparationProbe
    }

    private func makeHarness(decoderMode: AppleVideoDecoderMode = .automatic) throws -> Harness {
        let probe = PreparationProbe()
        let receiver = VideoStreamReceiver()
        let stream = try AppleVideoStream(
            receiver: receiver,
            video: AppleVideoNegotiation(
                viewerKey: Data(0..<46), serverKey: Data(0..<46),
                synchronizationSource: 0x5566_7788, canvas: Self.canvas,
                mediaStreamIndex: 0, displayIndex: 0
            ),
            connectionTiming: ConnectionStartupTrace(clock: { probe.now }, emit: { probe.record($0) }),
            decoderMode: decoderMode,
            clock: { probe.now },
            decoderFactory: { parameters, tileCount, mode in
                { _, _, _ in try probe.create(parameters: parameters, tileCount: tileCount, mode: mode) }
            }
        )
        stream.start()
        return Harness(stream: stream, receiver: receiver, probe: probe)
    }

    private func deliverInitialBurst(to harness: Harness) async throws {
        try await deliver(try packets(sequences: 0..<25), at: 100, to: harness)
    }

    private func deliver(_ packets: [Data], at time: TimeInterval, to harness: Harness) async throws {
        harness.probe.setTime(time)
        try await harness.receiver.deliver(packets, arrivalTime: time)
        // Delivery has enqueued its AUs. This public queue-ordered operation
        // completes after their playback work, without waiting on a timer/sleep.
        await harness.stream.updateCanvas(Self.canvas)
    }

    private func packets(
        sources: Range<UInt32> = 100..<104,
        sequences: Range<UInt16>,
        sequenceParameter: UInt8 = 0xbb,
        includesParameters: Bool = true
    ) throws -> [Data] {
        var datagrams = [Data]()
        for sequence in sequences {
            for source in sources {
                var payload = Data([0x60, 1])
                payload.appendUInt16BE(sequence * 4 + UInt16(source - sources.lowerBound))
                // Assembly fixtures only: the fake decoder does not parse HEVC.
                let parameters = includesParameters
                    ? [Data([0x40, 1, 0xaa]), Data([0x42, 1, sequenceParameter]), Data([0x44, 1, 0xcc])]
                    : []
                for nal in parameters + [Data([0x26, 1, 0xdd])] {
                    payload.appendUInt16BE(UInt16(nal.count))
                    payload.append(nal)
                }
                datagrams.append(try encrypt(payload, sequence: sequence, source: source))
            }
        }
        return datagrams
    }

    private func encrypt(_ payload: Data, sequence: UInt16, source: UInt32) throws -> Data {
        // Same authenticated SRTP fixture construction as AppleSRTPTests.
        let keys = try AppleSRTPKeySchedule(blob: Data(0..<46))
        var iv = keys.salt + Data(repeating: 0, count: 2)
        for offset in 0..<4 {
            iv[4 + offset] ^= UInt8(truncatingIfNeeded: source >> (24 - offset * 8))
        }
        iv[12] ^= UInt8(truncatingIfNeeded: sequence >> 8)
        iv[13] ^= UInt8(truncatingIfNeeded: sequence)
        var datagram = Data([0x80, 0xe0])
        datagram.appendUInt16BE(sequence)
        datagram.appendUInt32BE(UInt32(sequence) * 400)
        datagram.appendUInt32BE(source)
        datagram.append(try AppleProtocolAES.cryptCTR(payload, key: keys.cipherKey, initializationVector: iv))
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(
            for: datagram + Data(repeating: 0, count: 4),
            using: SymmetricKey(data: keys.authenticationKey)
        )
        datagram.append(contentsOf: authentication.prefix(10))
        return datagram
    }
}

private final class PreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var entries = [ConnectionStartupTrace.Entry]()
    private var storedAttempts = 0
    private var storedDecoders = [PreparedStreamDecoder]()
    private var storedParameters = [AppleHEVCParameterSets]()
    private var storedModes = [AppleVideoDecoderMode]()
    private var storedTileCounts = [Int]()
    var failFirstAttempt = false
    var onCreate: (() -> Void)?
    var onClose: (() -> Void)?

    var now: TimeInterval { lock.withLock { time } }
    var attempts: Int { lock.withLock { storedAttempts } }
    var decoders: [PreparedStreamDecoder] { lock.withLock { storedDecoders } }
    var parameters: [AppleHEVCParameterSets] { lock.withLock { storedParameters } }
    var modes: [AppleVideoDecoderMode] { lock.withLock { storedModes } }
    var tileCounts: [Int] { lock.withLock { storedTileCounts } }

    func setTime(_ time: TimeInterval) { lock.withLock { self.time = time } }
    func record(_ entry: ConnectionStartupTrace.Entry) { lock.withLock { entries.append(entry) } }
    func entry(_ stage: ConnectionStartupTrace.Stage) -> ConnectionStartupTrace.Entry? {
        lock.withLock { entries.first { $0.event.stage == stage } }
    }
    func duration(_ stage: ConnectionStartupTrace.Stage) -> Double {
        entry(stage)?.durationMilliseconds ?? -1
    }

    func create(
        parameters: AppleHEVCParameterSets, tileCount: Int, mode: AppleVideoDecoderMode
    ) throws -> PreparedStreamDecoder {
        onCreate?()
        return try lock.withLock {
            storedAttempts += 1
            time += 0.1
            if failFirstAttempt, storedAttempts == 1 {
                throw AppleHEVCDecoderError.incompleteParameterSets
            }
            let decoder = PreparedStreamDecoder(onClose: onClose)
            storedDecoders.append(decoder)
            storedParameters.append(parameters)
            storedModes.append(mode)
            storedTileCounts.append(tileCount)
            return decoder
        }
    }
}

private final class PreparedStreamDecoder: AppleHEVCDecodeSubmitting, @unchecked Sendable {
    let backend: AppleHEVCDecoder.Backend = .videoToolbox
    private let lock = NSLock()
    private var submittedOrders = [UInt16]()
    private var closed = false
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)?) { self.onClose = onClose }
    var orders: [UInt16] { lock.withLock { submittedOrders } }
    var isClosed: Bool { lock.withLock { closed } }

    func decode(
        _ nalUnits: [Data], tileIndex: Int, decodingOrderNumber: UInt16?,
        isLongTermReferenceFrame: Bool, rtpTimestamp: UInt32, presentationTime: TimeInterval,
        timing: AppleHEVCAccessUnit.Timing?
    ) throws -> Bool {
        lock.withLock {
            if let decodingOrderNumber { submittedOrders.append(decodingOrderNumber) }
        }
        return true
    }

    func close() {
        let shouldNotify = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldNotify { onClose?() }
    }
}
