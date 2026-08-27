import CoreVideo
import VideoToolbox
import XCTest
@testable import iScreenSharing

final class AppleHEVCDecodePipelineTests: XCTestCase {
    private let sources: [UInt32] = [100, 200, 300, 400]

    func testForwardGapOverflowKeepsStableDecoderRunning() throws {
        let harness = try makeHarness()

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10])

        harness.pipeline.submit((12...20).map { order in
            accessUnit(
                source: sources[Int(order) % sources.count],
                timestamp: UInt32(order),
                order: UInt16(order)
            )
        })
        XCTAssertEqual(
            harness.decoder.submissions.compactMap(\.order),
            [10] + Array(12...20).map(UInt16.init)
        )
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testForwardsLongTermReferenceMetadataWithDecodingOrderNumber() throws {
        let harness = try makeHarness()

        harness.pipeline.submit([
            accessUnit(
                source: 100,
                timestamp: 1,
                order: 0xabcd,
                isLongTermReferenceFrame: true
            ),
        ])

        XCTAssertEqual(harness.decoder.submissions.count, 1)
        XCTAssertEqual(harness.decoder.submissions[0].order, 0xabcd)
        XCTAssertTrue(harness.decoder.submissions[0].isLongTermReferenceFrame)
    }

    func testForwardsLongTermReferenceCompletionWithoutAFrame() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.ltr")
        let decoder = FakeDecoder()
        var acknowledgements = [UInt16]()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { _ in XCTFail("LTR completion must not publish a frame") },
            longTermReferenceHandler: { acknowledgements.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        decoder.emitLongTermReference(0xabcd)
        callbackQueue.sync {}

        XCTAssertEqual(acknowledgements, [0xabcd])
        pipeline.close()
    }

    func testSynchronousDecodeFailureKeepsSubmittingWithoutReplacingDecoder() throws {
        let harness = try makeHarness()
        harness.decoder.nextError = AppleHEVCDecoderError.decodeFailed(-12909)

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testSynchronousReferenceMissingKeepsSubmittingToStableDecoder() throws {
        let harness = try makeHarness()
        harness.decoder.nextError = AppleHEVCDecoderError.decodeFailed(
            kVTVideoDecoderReferenceMissingErr
        )

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testRecoverableReferenceMissingFailureKeepsSubmittingToStableDecoder() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderReferenceMissingErr
        )
        harness.callbackQueue.sync {}
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testReferenceMissingFailuresShareOneRefreshUntilOutputRecovers() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        for timestamp in UInt32(1)...4 {
            harness.decoder.emitFailure(
                timestamp: timestamp,
                status: kVTVideoDecoderReferenceMissingErr
            )
        }
        harness.callbackQueue.sync {}
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 5, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testDuplicateReferenceMissingTimestampRequestsOneRefresh() throws {
        let harness = try makeHarness()

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderReferenceMissingErr
        )
        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderReferenceMissingErr
        )
        harness.callbackQueue.sync {}

        XCTAssertEqual(harness.refreshRequests, [1])
    }

    func testSuccessfulFrameAllowsALaterReferenceMissingFailureToRequestRefresh() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderReferenceMissingErr
        )
        harness.callbackQueue.sync {}
        harness.decoder.emitFrame(timestamp: 2)
        harness.callbackQueue.sync {}
        harness.decoder.emitFailure(
            timestamp: 3,
            status: kVTVideoDecoderReferenceMissingErr
        )
        harness.callbackQueue.sync {}

        XCTAssertEqual(harness.refreshRequests, [1, 3])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testAsynchronousDecodeFailureKeepsSubmittingAndIgnoresLateCallbacksAfterClose() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        harness.decoder.emitFailure(timestamp: 1)
        harness.callbackQueue.sync {}
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.decoderFactoryCount, 1)

        harness.pipeline.close()
        harness.decoder.emitFailure(timestamp: 2)
        harness.callbackQueue.sync {}

        XCTAssertTrue(harness.decoder.isClosed)
    }

    func testNoVideoWatchdogResetsOnlyDecodingOrderAdmission() throws {
        let harness = try makeHarness()

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 9)])
        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10])

        harness.pipeline.resetDecodingOrder()
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 3, order: 9)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 9])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testFormatChangeReplacesOnlyDecoderAndPreservesAdmissionState() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.format-change")
        let callbacks = CallbackStore()
        let firstDecoder = FakeDecoder()
        let replacementDecoder = FakeDecoder()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: makeFactory(decoder: firstDecoder, callbacks: callbacks),
            frameHandler: { _ in },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        try pipeline.replaceDecoder(
            using: makeFactory(decoder: replacementDecoder, callbacks: callbacks)
        )
        pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 9)])
        pipeline.submit([accessUnit(source: 200, timestamp: 3, order: 11)])

        XCTAssertTrue(firstDecoder.isClosed)
        XCTAssertFalse(replacementDecoder.isClosed)
        XCTAssertEqual(firstDecoder.submissions.map(\.order), [10])
        XCTAssertEqual(replacementDecoder.submissions.map(\.order), [11])
        XCTAssertEqual(callbacks.decoderFactoryCount, 2)
    }

    func testPublishesEachVideoToolboxTileWithoutAFrameBarrier() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.tiles")
        let decoder = FakeDecoder()
        var frames = [AppleHEVCDecoder.DecodedFrame]()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { frames.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        decoder.emitFrame(timestamp: 90_000, region: .tile(2))
        callbackQueue.sync {}
        XCTAssertEqual(frames.map(\.region), [.tile(2)])
        pipeline.close()
    }

    func testSynchronizedVideoToolboxPublishesSparseSenderFrameAsOneBatch() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.synchronized")
        let decoder = FakeDecoder()
        var individualFrames = [AppleHEVCDecoder.DecodedFrame]()
        var batches = [[AppleHEVCDecoder.DecodedFrame]]()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { individualFrames.append($0) },
            frameBatchHandler: { batches.append($0) },
            synchronizesTileFrames: true,
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.submit([
            accessUnit(source: 100, timestamp: 90_000, order: 10, frameSequenceNumber: 0x1682),
            accessUnit(source: 400, timestamp: 90_000, order: 11, frameSequenceNumber: 0x1682),
        ])
        decoder.emitFrame(
            timestamp: 90_000,
            region: .tile(3),
            frameSequenceNumber: 0x1682
        )
        decoder.emitFrame(
            timestamp: 90_000,
            region: .tile(0),
            frameSequenceNumber: 0x1682
        )
        pipeline.submit([
            accessUnit(source: 200, timestamp: 91_500, order: 12, frameSequenceNumber: 0x1683),
        ])
        callbackQueue.sync {}
        callbackQueue.sync {}

        XCTAssertTrue(individualFrames.isEmpty)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.region), [.tile(0), .tile(3)])
        pipeline.close()
    }

    func testSynchronizedVideoToolboxPublishesOnLastSubframeWithoutNextSequence() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.last-subframe")
        let decoder = FakeDecoder()
        var batches = [[AppleHEVCDecoder.DecodedFrame]]()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { _ in XCTFail("Expected an atomic batch") },
            frameBatchHandler: { batches.append($0) },
            synchronizesTileFrames: true,
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.submit([
            accessUnit(
                source: 100,
                timestamp: 90_000,
                order: 10,
                frameSequenceNumber: 0x1682,
                subframeBoundary: .notLast
            ),
            accessUnit(
                source: 400,
                timestamp: 90_000,
                order: 11,
                frameSequenceNumber: 0x1682,
                subframeBoundary: .last
            ),
        ])
        decoder.emitFrame(
            timestamp: 90_000,
            region: .tile(0),
            frameSequenceNumber: 0x1682
        )
        decoder.emitFrame(
            timestamp: 90_000,
            region: .tile(3),
            frameSequenceNumber: 0x1682
        )
        callbackQueue.sync {}
        callbackQueue.sync {}

        XCTAssertEqual(batches.map { $0.map(\.region) }, [[.tile(0), .tile(3)]])
        pipeline.close()
    }

    func testCanEnableSynchronizedTilePresentationWithoutReplacingDecoder() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.mode-change")
        let decoder = FakeDecoder()
        var individualFrames = [AppleHEVCDecoder.DecodedFrame]()
        var batches = [[AppleHEVCDecoder.DecodedFrame]]()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { individualFrames.append($0) },
            frameBatchHandler: { batches.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.setSynchronizesTileFrames(true)
        pipeline.submit([
            accessUnit(source: 300, timestamp: 90_000, order: 10, frameSequenceNumber: 8),
        ])
        decoder.emitFrame(timestamp: 90_000, region: .tile(2), frameSequenceNumber: 8)
        pipeline.submit([
            accessUnit(source: 100, timestamp: 91_500, order: 11, frameSequenceNumber: 9),
        ])
        callbackQueue.sync {}
        callbackQueue.sync {}

        XCTAssertTrue(individualFrames.isEmpty)
        XCTAssertEqual(batches.map { $0.map(\.region) }, [[.tile(2)]])
        XCTAssertFalse(decoder.isClosed)
        pipeline.close()
    }

    func testDecoderReplacementRejectsLateCallbacksFromOldGeneration() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.generation")
        let firstDecoder = FakeDecoder()
        let replacementDecoder = FakeDecoder()
        var frames = [AppleHEVCDecoder.DecodedFrame]()
        let directFactory: (FakeDecoder) -> AppleHEVCDecodePipeline.DecoderFactory = { decoder in
            { failure, frame, longTermReference in
                decoder.failureHandler = failure
                decoder.frameHandler = frame
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            }
        }
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: directFactory(firstDecoder),
            frameHandler: { frames.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        firstDecoder.emitFrame(timestamp: 12, region: .tile(0))
        callbackQueue.sync {}
        try pipeline.replaceDecoder(using: directFactory(replacementDecoder))
        firstDecoder.emitFrame(timestamp: 12, region: .tile(0))
        replacementDecoder.emitFrame(timestamp: 12, region: .tile(1))
        callbackQueue.sync {}
        XCTAssertEqual(frames.map(\.region), [.tile(0), .tile(1)])
        pipeline.close()
    }

    private func makeHarness() throws -> Harness {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.callback")
        let decoder = FakeDecoder()
        let callbacks = CallbackStore()
        let pipeline = try AppleHEVCDecodePipeline(
            tileCount: sources.count,
            sourceToTile: Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) }),
            callbackQueue: callbackQueue,
            decoderFactory: { failure, frame, longTermReference in
                callbacks.install(failureHandler: failure, frameHandler: frame)
                decoder.longTermReferenceHandler = longTermReference
                return decoder
            },
            frameHandler: { _ in },
            refreshHandler: { callbacks.recordRefresh(timestamp: $0) },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )
        decoder.failureHandler = { callbacks.emitFailure($0) }
        decoder.frameHandler = { callbacks.emitFrame($0) }
        return Harness(
            pipeline: pipeline,
            decoder: decoder,
            callbackQueue: callbackQueue,
            callbacks: callbacks
        )
    }

    private func makeFactory(
        decoder: FakeDecoder,
        callbacks: CallbackStore
    ) -> AppleHEVCDecodePipeline.DecoderFactory {
        { failure, frame, longTermReference in
            callbacks.install(failureHandler: failure, frameHandler: frame)
            decoder.failureHandler = { callbacks.emitFailure($0) }
            decoder.frameHandler = { callbacks.emitFrame($0) }
            decoder.longTermReferenceHandler = longTermReference
            return decoder
        }
    }

    private func accessUnit(
        source: UInt32,
        timestamp: UInt32,
        order: UInt16,
        isRefresh: Bool = false,
        isLongTermReferenceFrame: Bool = false,
        frameSequenceNumber: UInt16? = nil,
        subframeBoundary: AppleHEVCSubframeBoundaryParser.Boundary = .unknown
    ) -> AppleHEVCAccessUnit {
        AppleHEVCAccessUnit(
            synchronizationSource: source,
            timestamp: timestamp,
            decodingOrderNumber: order,
            nalUnits: [Data([isRefresh ? 0x26 : 0x02, 0x01])],
            isLongTermReferenceFrame: isLongTermReferenceFrame,
            subframeBoundary: subframeBoundary,
            timing: frameSequenceNumber.map {
                AppleHEVCAccessUnit.Timing(
                    traceSequence: UInt64($0),
                    observedFrameSequenceNumber: $0,
                    firstDatagramObservedAt: 0,
                    completingDatagramObservedAt: 0,
                    assemblyCompletedAt: 0
                )
            }
        )
    }
}

private extension AppleHEVCDecodePipelineTests {
    final class Harness {
        let pipeline: AppleHEVCDecodePipeline
        let decoder: FakeDecoder
        let callbackQueue: DispatchQueue
        private let callbacks: CallbackStore

        init(
            pipeline: AppleHEVCDecodePipeline,
            decoder: FakeDecoder,
            callbackQueue: DispatchQueue,
            callbacks: CallbackStore
        ) {
            self.pipeline = pipeline
            self.decoder = decoder
            self.callbackQueue = callbackQueue
            self.callbacks = callbacks
        }

        var decoderFactoryCount: Int { callbacks.decoderFactoryCount }
        var refreshRequests: [UInt32] { callbacks.refreshRequests }
    }

    final class CallbackStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFailureHandler: AppleHEVCDecoder.FailureHandler?
        private var storedFrameHandler: AppleHEVCDecoder.FrameHandler?
        private var storedDecoderFactoryCount = 0
        private var storedRefreshRequests = [UInt32]()

        var decoderFactoryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedDecoderFactoryCount
        }

        var refreshRequests: [UInt32] {
            lock.lock()
            defer { lock.unlock() }
            return storedRefreshRequests
        }

        func install(
            failureHandler: @escaping AppleHEVCDecoder.FailureHandler,
            frameHandler: @escaping AppleHEVCDecoder.FrameHandler
        ) {
            lock.lock()
            storedFailureHandler = failureHandler
            storedFrameHandler = frameHandler
            storedDecoderFactoryCount += 1
            lock.unlock()
        }

        func recordRefresh(timestamp: UInt32) {
            lock.lock()
            storedRefreshRequests.append(timestamp)
            lock.unlock()
        }

        func emitFailure(_ failure: AppleHEVCDecoder.DecodeFailure) {
            lock.lock()
            let handler = storedFailureHandler
            lock.unlock()
            handler?(failure)
        }

        func emitFrame(_ frame: AppleHEVCDecoder.DecodedFrame) {
            lock.lock()
            let handler = storedFrameHandler
            lock.unlock()
            handler?(frame)
        }
    }

    final class FakeDecoder: AppleHEVCDecodeSubmitting {
        struct Submission {
            let order: UInt16?
            let isLongTermReferenceFrame: Bool
            let timestamp: UInt32
        }

        var submissions = [Submission]()
        var nextError: Error?
        var isClosed = false
        var failureHandler: AppleHEVCDecoder.FailureHandler?
        var frameHandler: AppleHEVCDecoder.FrameHandler?
        var longTermReferenceHandler: AppleHEVCDecoder.LongTermReferenceHandler?

        func decode(
            _ nalUnits: [Data],
            tileIndex: Int,
            decodingOrderNumber: UInt16?,
            isLongTermReferenceFrame: Bool,
            rtpTimestamp: UInt32,
            presentationTime: TimeInterval,
            timing: AppleHEVCAccessUnit.Timing?
        ) throws -> Bool {
            submissions.append(Submission(
                order: decodingOrderNumber,
                isLongTermReferenceFrame: isLongTermReferenceFrame,
                timestamp: rtpTimestamp
            ))
            if let nextError {
                self.nextError = nil
                throw nextError
            }
            return true
        }

        func close() {
            isClosed = true
        }

        func emitFailure(timestamp: UInt32, status: OSStatus = -12909) {
            failureHandler?(AppleHEVCDecoder.DecodeFailure(
                tileIndex: 0,
                rtpTimestamp: timestamp,
                status: status
            ))
        }

        func emitLongTermReference(_ decodingOrderNumber: UInt16) {
            longTermReferenceHandler?(decodingOrderNumber)
        }

        func emitFrame(
            timestamp: UInt32,
            region: AppleHEVCDecoder.FrameRegion = .fullCanvas,
            frameSequenceNumber: UInt16? = nil
        ) {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault,
                1,
                1,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ), kCVReturnSuccess)
            guard let pixelBuffer else {
                XCTFail("Could not create test pixel buffer")
                return
            }
            frameHandler?(AppleHEVCDecoder.DecodedFrame(
                region: region,
                decodingOrderNumber: nil,
                rtpTimestamp: timestamp,
                presentationTime: 0,
                decodeDuration: 0,
                accessUnitTiming: frameSequenceNumber.map {
                    AppleHEVCAccessUnit.Timing(
                        traceSequence: UInt64($0),
                        observedFrameSequenceNumber: $0,
                        firstDatagramObservedAt: 0,
                        completingDatagramObservedAt: 0,
                        assemblyCompletedAt: 0
                    )
                },
                decodeEnteredAt: 0,
                decoderSubmittedAt: 0,
                decoderOutputAt: 0,
                pixelBuffer: pixelBuffer
            ))
        }
    }
}
