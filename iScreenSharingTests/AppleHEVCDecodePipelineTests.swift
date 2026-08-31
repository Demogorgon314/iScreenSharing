import CoreVideo
import struct ScreenSharingProtocol.AppleHEVCSubframeBoundaryParser
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
            outputHandler: { _ in XCTFail("LTR completion must not publish a frame") },
            longTermReferenceHandler: { acknowledgements.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        decoder.emitLongTermReference(0xabcd)
        callbackQueue.sync {}

        XCTAssertEqual(acknowledgements, [0xabcd])
        pipeline.close()
    }

    func testSynchronousBadDataRequestsRefreshAndKeepsSubmittingWithoutReplacingDecoder() throws {
        let harness = try makeHarness()
        harness.decoder.nextError = AppleHEVCDecoderError.decodeFailed(
            kVTVideoDecoderBadDataErr
        )

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testNativeSynchronousRefreshClassifierUsesOnlyRawVCPStatuses() {
        for status in [
            kVTVideoDecoderReferenceMissingErr,
            kVTVideoDecoderBadDataErr,
            OSStatus(-8969),
            OSStatus(-100),
        ] {
            XCTAssertTrue(
                AppleHEVCDecodePipeline.nativeSynchronousStatusRequestsRefresh(status),
                "Expected native refresh classification for \(status)"
            )
        }

        for status in [
            kVTVideoEncoderMalfunctionErr,
            OSStatus(-1),
            OSStatus(bitPattern: 0xA004_326D),
        ] {
            XCTAssertFalse(
                AppleHEVCDecodePipeline.nativeSynchronousStatusRequestsRefresh(status),
                "Unexpected native refresh classification for \(status)"
            )
        }
    }

    func testSynchronousEncoderMalfunctionDoesNotInventAnImmediateNativeRefresh() throws {
        let harness = try makeHarness()
        harness.decoder.nextError = AppleHEVCDecoderError.decodeFailed(
            kVTVideoEncoderMalfunctionErr
        )

        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertTrue(harness.refreshRequests.isEmpty)
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testAsynchronousBadDataRequestsRefreshAndKeepsSubmittingToStableDecoder() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderBadDataErr
        )
        harness.callbackQueue.sync {}
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 2, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1])
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testEveryAsynchronousDecoderStatusRequestsRefresh() throws {
        let statuses = [
            kVTVideoDecoderReferenceMissingErr,
            kVTVideoDecoderBadDataErr,
            kVTVideoEncoderMalfunctionErr,
            OSStatus(-42),
        ]
        for (index, status) in statuses.enumerated() {
            let harness = try makeHarness()
            let timestamp = UInt32(index + 1)

            harness.decoder.emitFailure(timestamp: timestamp, status: status)
            harness.callbackQueue.sync {}

            XCTAssertEqual(harness.refreshRequests, [timestamp])
            XCTAssertEqual(harness.decoderFactoryCount, 1)
            XCTAssertFalse(harness.decoder.isClosed)
            harness.pipeline.close()
        }
    }

    func testNonDecoderCallbackFailuresDoNotRequestRefresh() throws {
        let harness = try makeHarness()

        harness.decoder.emitFailure(
            timestamp: 1,
            status: noErr,
            reason: .frameDropped
        )
        harness.decoder.emitFailure(
            timestamp: 2,
            status: noErr,
            reason: .missingImageBuffer
        )
        harness.callbackQueue.sync {}

        XCTAssertTrue(harness.refreshRequests.isEmpty)
    }

    func testBadDataFailuresRequestRefreshForEachNewTimestamp() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        for timestamp in UInt32(1)...4 {
            harness.decoder.emitFailure(
                timestamp: timestamp,
                status: kVTVideoDecoderBadDataErr
            )
        }
        harness.callbackQueue.sync {}
        harness.pipeline.submit([accessUnit(source: 200, timestamp: 5, order: 11)])

        XCTAssertEqual(harness.decoder.submissions.map(\.order), [10, 11])
        XCTAssertEqual(harness.refreshRequests, [1, 2, 3, 4])
        XCTAssertEqual(
            harness.refreshEvents.map(\.startsRefreshState),
            [true, false, false, false]
        )
        XCTAssertEqual(harness.decoderFactoryCount, 1)
        XCTAssertFalse(harness.decoder.isClosed)
    }

    func testDuplicateBadDataTimestampRequestsOneRefresh() throws {
        let harness = try makeHarness()

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderBadDataErr
        )
        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderBadDataErr
        )
        harness.callbackQueue.sync {}

        XCTAssertEqual(harness.refreshRequests, [1])
    }

    func testChangedTimestampRequestsLaterRefreshWithoutWaitingForOutput() throws {
        let harness = try makeHarness()
        harness.pipeline.submit([accessUnit(source: 100, timestamp: 1, order: 10)])

        harness.decoder.emitFailure(
            timestamp: 1,
            status: kVTVideoDecoderBadDataErr
        )
        harness.callbackQueue.sync {}
        harness.decoder.emitFailure(
            timestamp: 3,
            status: kVTVideoDecoderBadDataErr
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
            outputHandler: { _ in },
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
            outputHandler: { frames.append(contentsOf: $0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        decoder.emitFrame(timestamp: 90_000, region: .tile(2))
        callbackQueue.sync {}
        XCTAssertEqual(frames.map(\.region), [.tile(2)])
        pipeline.close()
    }

    func testVideoProcessingPreferenceSynchronizesActualVideoToolboxFallback() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.synchronized")
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
            outputHandler: { batches.append($0) },
            synchronizesVideoToolboxTiles:
                AppleVideoDecoderMode.videoProcessing.synchronizesVideoToolboxTiles,
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

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.region), [.tile(0), .tile(3)])
        pipeline.close()
    }

    func testVideoProcessingPreferenceBypassesSynchronizationForActualVCPBackend() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.vcp")
        let decoder = FakeDecoder()
        decoder.backend = .videoProcessing
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
            outputHandler: { batches.append($0) },
            synchronizesVideoToolboxTiles: true,
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        decoder.emitFrame(timestamp: 90_000, region: .fullCanvas)
        callbackQueue.sync {}

        XCTAssertEqual(batches.map { $0.map(\.region) }, [[.fullCanvas]])
        pipeline.close()
    }

    func testDroppedVideoToolboxTileDoesNotBlockLaterSynchronizedFrames() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.dropped")
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
            outputHandler: { batches.append($0) },
            synchronizesVideoToolboxTiles: true,
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.submit([
            accessUnit(
                source: 100,
                timestamp: 90_000,
                order: 10,
                frameSequenceNumber: 8,
                subframeBoundary: .last
            ),
        ])
        decoder.emitFailure(
            timestamp: 90_000,
            tileIndex: 0,
            frameSequenceNumber: 8,
            status: noErr,
            reason: .frameDropped
        )
        pipeline.submit([
            accessUnit(
                source: 200,
                timestamp: 91_500,
                order: 11,
                frameSequenceNumber: 9,
                subframeBoundary: .last
            ),
        ])
        decoder.emitFrame(timestamp: 91_500, region: .tile(1), frameSequenceNumber: 9)
        callbackQueue.sync {}
        callbackQueue.sync {}

        XCTAssertEqual(batches.map { $0.map(\.region) }, [[.tile(1)]])
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
            outputHandler: { batches.append($0) },
            synchronizesVideoToolboxTiles: true,
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

    func testDiagnosticsExposeAcceptedVideoToolboxDecodeBlockingSynchronizedOutput() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.diagnostics")
        let decoder = FakeDecoder()
        let callbacks = CallbackStore()
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
            outputHandler: { callbacks.recordOutput($0) },
            synchronizesVideoToolboxTiles: true,
            freezeDiagnosticsEnabled: true,
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.submit([
            accessUnit(
                source: 100,
                timestamp: 90_000,
                order: 10,
                frameSequenceNumber: 42,
                subframeBoundary: .last
            ),
        ])

        var diagnostics = pipeline.diagnostics()
        XCTAssertEqual(diagnostics.decoderBackend, .videoToolbox)
        XCTAssertEqual(diagnostics.selectedAccessUnitCount, 1)
        XCTAssertEqual(diagnostics.admittedAccessUnitCount, 1)
        XCTAssertEqual(diagnostics.videoSliceCount, 1)
        XCTAssertEqual(diagnostics.acceptedDecodeCount, 1)
        XCTAssertEqual(diagnostics.rejectedDecodeCount, 0)
        XCTAssertEqual(diagnostics.decoderCallbackCount, 0)
        XCTAssertEqual(diagnostics.outstandingDecodeCount, 1)
        XCTAssertEqual(diagnostics.maximumOutstandingDecodeCount, 1)
        XCTAssertNotNil(diagnostics.lastSelectedAccessUnitAt)
        XCTAssertNotNil(diagnostics.lastDecodeAttemptAt)
        XCTAssertNil(diagnostics.lastDecoderCallbackAt)
        XCTAssertEqual(diagnostics.tileSynchronization.pendingGroupCount, 1)
        XCTAssertEqual(diagnostics.tileSynchronization.oldestFrameSequenceNumber, 42)
        XCTAssertEqual(diagnostics.tileSynchronization.oldestSubmittedTileCount, 1)
        XCTAssertEqual(diagnostics.tileSynchronization.oldestDecodedTileCount, 0)
        XCTAssertTrue(diagnostics.tileSynchronization.oldestGroupIsClosed)
        XCTAssertTrue(callbacks.outputBatches.isEmpty)

        decoder.emitFrame(timestamp: 90_000, region: .tile(0), frameSequenceNumber: 42)
        callbackQueue.sync {}
        callbackQueue.sync {}

        diagnostics = pipeline.diagnostics()
        XCTAssertEqual(diagnostics.decoderCallbackCount, 1)
        XCTAssertEqual(diagnostics.outstandingDecodeCount, 0)
        XCTAssertNotNil(diagnostics.lastDecoderCallbackAt)
        XCTAssertEqual(diagnostics.tileSynchronization, .empty)
        XCTAssertEqual(callbacks.outputBatches.map { $0.map(\.region) }, [[.tile(0)]])
        pipeline.close()
    }

    func testCanEnableSynchronizedTilePresentationWithoutReplacingDecoder() throws {
        let callbackQueue = DispatchQueue(label: "AppleHEVCDecodePipelineTests.mode-change")
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
            outputHandler: { batches.append($0) },
            refreshHandler: { _ in },
            errorHandler: { XCTFail("Unexpected pipeline error: \($0)") }
        )

        pipeline.setSynchronizesVideoToolboxTiles(true)
        pipeline.submit([
            accessUnit(source: 300, timestamp: 90_000, order: 10, frameSequenceNumber: 8),
        ])
        decoder.emitFrame(timestamp: 90_000, region: .tile(2), frameSequenceNumber: 8)
        pipeline.submit([
            accessUnit(source: 100, timestamp: 91_500, order: 11, frameSequenceNumber: 9),
        ])
        callbackQueue.sync {}
        callbackQueue.sync {}

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
            outputHandler: { frames.append(contentsOf: $0) },
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
            outputHandler: { _ in },
            refreshHandler: { callbacks.recordRefresh($0) },
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
        var refreshEvents: [AppleHEVCDecodeRefreshRequest] { callbacks.refreshEvents }
    }

    final class CallbackStore: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFailureHandler: AppleHEVCDecoder.FailureHandler?
        private var storedFrameHandler: AppleHEVCDecoder.FrameHandler?
        private var storedDecoderFactoryCount = 0
        private var storedRefreshEvents = [AppleHEVCDecodeRefreshRequest]()
        private var storedOutputBatches = [[AppleHEVCDecoder.DecodedFrame]]()

        var decoderFactoryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedDecoderFactoryCount
        }

        var refreshRequests: [UInt32] {
            lock.lock()
            defer { lock.unlock() }
            return storedRefreshEvents.map(\.timestamp)
        }

        var refreshEvents: [AppleHEVCDecodeRefreshRequest] {
            lock.lock()
            defer { lock.unlock() }
            return storedRefreshEvents
        }

        var outputBatches: [[AppleHEVCDecoder.DecodedFrame]] {
            lock.lock()
            defer { lock.unlock() }
            return storedOutputBatches
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

        func recordRefresh(_ request: AppleHEVCDecodeRefreshRequest) {
            lock.lock()
            storedRefreshEvents.append(request)
            lock.unlock()
        }

        func recordOutput(_ frames: [AppleHEVCDecoder.DecodedFrame]) {
            lock.lock()
            storedOutputBatches.append(frames)
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
        var backend: AppleHEVCDecoder.Backend = .videoToolbox

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

        func emitFailure(
            timestamp: UInt32,
            tileIndex: Int = 0,
            frameSequenceNumber: UInt16? = nil,
            status: OSStatus = -12909,
            reason: AppleHEVCDecoder.DecodeFailure.Reason = .decoderStatus
        ) {
            failureHandler?(AppleHEVCDecoder.DecodeFailure(
                tileIndex: tileIndex,
                rtpTimestamp: timestamp,
                frameSequenceNumber: frameSequenceNumber,
                status: status,
                reason: reason
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
