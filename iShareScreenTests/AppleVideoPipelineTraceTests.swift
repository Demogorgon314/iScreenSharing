import XCTest
@testable import iShareScreen

final class AppleVideoPipelineTraceTests: XCTestCase {
    func testCorrelatesFrameDeliveryMetalAndDisplayTimings() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: .init(
                traceSequence: 1,
                firstDatagramObservedAt: -0.006,
                completingDatagramObservedAt: -0.005,
                assemblyCompletedAt: -0.004
            ),
            decodeEnteredAt: -0.002,
            decoderSubmittedAt: -0.001,
            decoderOutputAt: 0,
            playbackHandledAt: 0.001,
            mainDeliveredAt: 0.003,
            presentationTime: 0.002
        )
        trace.recordFrameDelivery(
            frameKey: 2,
            accessUnitTiming: .init(
                traceSequence: 2,
                firstDatagramObservedAt: -0.0055,
                completingDatagramObservedAt: -0.0045,
                assemblyCompletedAt: -0.0035
            ),
            decodeEnteredAt: -0.0015,
            decoderSubmittedAt: -0.0005,
            decoderOutputAt: 0.0005,
            playbackHandledAt: 0.0015,
            mainDeliveredAt: 0.003,
            presentationTime: 0.0025
        )
        trace.recordSchedulerSelection(frameKeys: [1, 2], selectedAt: 0.004)
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1, 2],
            drawableWaitStartedAt: 0.005,
            drawableAcquiredAt: 0.006,
            encodeStartedAt: 0.006,
            encodeEndedAt: 0.007,
            targetTimestamp: 0.010,
            displayPeriod: 0.005,
            isDisplayLinkTriggered: true
        ))
        trace.recordCommitted(batchID: batchID, at: 0.0075)
        trace.recordScheduled(batchID: batchID, at: 0.008)
        trace.recordPresented(batchID: batchID, at: 0.015)

        XCTAssertEqual(trace.sample(at: 0.015), .zero)

        trace.recordCompleted(batchID: batchID, gpuStart: 0.0085, gpuEnd: 0.009)
        let snapshot = trace.sample(at: 0.016)

        XCTAssertEqual(snapshot.datagramSpanMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.completingDatagramToAssemblyMilliseconds.p50,
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.assemblyToDecodeEntryMilliseconds.p50, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.decodeEntryToSubmitMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderSubmitToCallbackMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderCallbackToPlaybackMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.playbackToMainMilliseconds.p50, 1.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.playbackToMainMilliseconds.p95, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.mainToSchedulerMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.schedulerToDrawableMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.drawableWaitMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.encodeMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.encodeEndToCommitMilliseconds.p50, 0.5, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.commitToScheduledCallbackMilliseconds.p50,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.gpuQueueWaitMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpuExecutionMilliseconds.p50, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpuEndToDisplayMilliseconds.p50, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.commitToDisplayMilliseconds.p50, 7.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.firstDatagramToDisplayMilliseconds.p50, 20.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.firstDatagramToDisplayMilliseconds.p95, 21, accuracy: 0.001)
        XCTAssertEqual(snapshot.decodeEntryToDisplayMilliseconds.p50, 16.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.decodeEntryToDisplayMilliseconds.p95, 17, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderSubmitToDisplayMilliseconds.p50, 15.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderSubmitToDisplayMilliseconds.p95, 16, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderCallbackToDisplayMilliseconds.p50, 14.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderCallbackToDisplayMilliseconds.p95, 15, accuracy: 0.001)
        XCTAssertEqual(snapshot.schedulerToTargetMilliseconds.p50, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentationToTargetMilliseconds.p50, 7.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentationToTargetMilliseconds.p95, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.commitLeadToTargetMilliseconds.p50, 2.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.gpuEndLeadToTargetMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.targetToDisplayMilliseconds.p50, 5, accuracy: 0.001)
        XCTAssertEqual(snapshot.targetPhasePeriods.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayLinkMissCount, 1)
        XCTAssertEqual(snapshot.immediatePreviousTargetAgeMilliseconds, .zero)
        XCTAssertEqual(snapshot.displayLinkBatchCount, 1)
        XCTAssertEqual(snapshot.immediateBatchCount, 0)
        XCTAssertEqual(snapshot.finalizedBatchCount, 1)
        XCTAssertEqual(snapshot.traceEvictionCount, 0)
    }

    func testDuplicateFrameSnapshotsKeepFirstMainDeliveryTime() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: -0.001,
            decoderSubmittedAt: -0.0005,
            decoderOutputAt: 0,
            playbackHandledAt: 0.001,
            mainDeliveredAt: 0.002,
            presentationTime: 0.002
        )
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: -0.001,
            decoderSubmittedAt: -0.0005,
            decoderOutputAt: 0,
            playbackHandledAt: 0.001,
            mainDeliveredAt: 0.100,
            presentationTime: 0.002
        )
        trace.recordSchedulerSelection(frameKeys: [1], selectedAt: 0.003)
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0.004,
            drawableAcquiredAt: 0.004,
            encodeStartedAt: 0.004,
            encodeEndedAt: 0.004,
            targetTimestamp: 0.0035,
            displayPeriod: 1.0 / 120,
            isDisplayLinkTriggered: false
        ))
        trace.recordCommitted(batchID: batchID, at: 0.004)
        trace.recordCompleted(batchID: batchID, gpuStart: 0.004, gpuEnd: 0.004)
        trace.recordPresented(batchID: batchID, at: 0.005)

        let snapshot = trace.sample(at: 0.006)

        XCTAssertEqual(snapshot.playbackToMainMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.mainToSchedulerMilliseconds.p50, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.targetToDisplayMilliseconds, .zero)
        XCTAssertEqual(
            snapshot.immediatePreviousTargetAgeMilliseconds.p50,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.displayLinkBatchCount, 0)
        XCTAssertEqual(snapshot.immediateBatchCount, 1)
    }

    func testEvictsIncompleteTracesAfterTwoSeconds() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0,
            decoderOutputAt: 0,
            playbackHandledAt: 0,
            mainDeliveredAt: 0,
            presentationTime: 0
        )
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: 0,
            displayPeriod: 1.0 / 60,
            isDisplayLinkTriggered: true
        ))
        trace.recordCommitted(batchID: batchID, at: 0)

        let snapshot = trace.sample(at: 2.001)

        XCTAssertEqual(snapshot.finalizedBatchCount, 0)
        XCTAssertEqual(snapshot.traceEvictionCount, 2)
    }

    func testFrameCapacityDoesNotEvictAnActiveRenderBatch() throws {
        var trace = AppleVideoPipelineTrace()
        let activeFrameKeys = (1...512).map(UInt64.init)
        for frameKey in activeFrameKeys {
            trace.recordFrameDelivery(
                frameKey: frameKey,
                accessUnitTiming: nil,
                decodeEnteredAt: 0,
                decoderSubmittedAt: 0,
                decoderOutputAt: 0,
                playbackHandledAt: 0,
                mainDeliveredAt: 0,
                presentationTime: 0
            )
        }
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: activeFrameKeys,
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: 0,
            displayPeriod: 1.0 / 60,
            isDisplayLinkTriggered: true
        ))

        trace.recordFrameDelivery(
            frameKey: 513,
            accessUnitTiming: nil,
            decodeEnteredAt: 0.001,
            decoderSubmittedAt: 0.001,
            decoderOutputAt: 0.001,
            playbackHandledAt: 0.001,
            mainDeliveredAt: 0.001,
            presentationTime: 0.001
        )
        trace.recordCommitted(batchID: batchID, at: 0)
        trace.recordScheduled(batchID: batchID, at: 0)
        trace.recordCompleted(batchID: batchID, gpuStart: 0, gpuEnd: 0)
        trace.recordPresented(batchID: batchID, at: 0.001)

        let snapshot = trace.sample(at: 0.002)

        XCTAssertEqual(snapshot.finalizedBatchCount, 1)
        XCTAssertEqual(snapshot.traceEvictionCount, 1)
    }

    func testResetDiscardsInFlightStateAndAccumulatedSamples() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0,
            decoderOutputAt: 0,
            playbackHandledAt: 0,
            mainDeliveredAt: 0,
            presentationTime: 0
        )
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: 0,
            displayPeriod: 1.0 / 60,
            isDisplayLinkTriggered: true
        ))
        trace.recordCommitted(batchID: batchID, at: 0)
        trace.recordCompleted(batchID: batchID, gpuStart: 0, gpuEnd: 0)
        trace.recordPresented(batchID: batchID, at: 0.001)

        trace.reset()

        XCTAssertEqual(trace.sample(at: 3), .zero)
    }

    func testScheduledCallbackCanArriveAfterPresentedAndCompleted() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0,
            decoderOutputAt: 0,
            playbackHandledAt: 0,
            mainDeliveredAt: 0,
            presentationTime: 0
        )
        trace.recordSchedulerSelection(frameKeys: [1], selectedAt: 0)
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: 0.010,
            displayPeriod: 0.005,
            isDisplayLinkTriggered: true
        ))
        trace.recordCommitted(batchID: batchID, at: 0.001)
        trace.recordPresented(batchID: batchID, at: 0.015)
        trace.recordCompleted(batchID: batchID, gpuStart: 0.002, gpuEnd: 0.003)
        trace.recordScheduled(batchID: batchID, at: 0.0015)

        let snapshot = trace.sample(at: 0.016)

        XCTAssertEqual(snapshot.finalizedBatchCount, 1)
        XCTAssertEqual(
            snapshot.commitToScheduledCallbackMilliseconds.p50,
            0.5,
            accuracy: 0.001
        )
    }

    func testMissingGPUTimestampsKeepsTargetAndEndToEndMetrics() throws {
        var trace = AppleVideoPipelineTrace()
        trace.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0.001,
            decoderOutputAt: 0.002,
            playbackHandledAt: 0.003,
            mainDeliveredAt: 0.004,
            presentationTime: 0.005
        )
        trace.recordSchedulerSelection(frameKeys: [1], selectedAt: 0.006)
        let batchID = try XCTUnwrap(trace.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0.007,
            drawableAcquiredAt: 0.007,
            encodeStartedAt: 0.007,
            encodeEndedAt: 0.008,
            targetTimestamp: 0.010,
            displayPeriod: 0.005,
            isDisplayLinkTriggered: true
        ))
        trace.recordCommitted(batchID: batchID, at: 0.0085)
        trace.recordScheduled(batchID: batchID, at: 0.009)
        trace.recordCompleted(batchID: batchID, gpuStart: nil, gpuEnd: nil)
        trace.recordPresented(batchID: batchID, at: 0.014)

        let snapshot = trace.sample(at: 0.015)

        XCTAssertEqual(snapshot.finalizedBatchCount, 1)
        XCTAssertEqual(snapshot.gpuExecutionMilliseconds, .zero)
        XCTAssertEqual(snapshot.commitToDisplayMilliseconds.p50, 5.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.decoderSubmitToDisplayMilliseconds.p50, 13, accuracy: 0.001)
        XCTAssertEqual(snapshot.targetPhasePeriods.p50, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayLinkMissCount, 0)
    }
}
