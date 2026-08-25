import XCTest
@testable import iShareScreen

final class AppleVideoPerformanceMonitorTests: XCTestCase {
    func testExposesMostRecentPresentedFrameForPlaybackWatchdog() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            automaticallyPublishes: false
        )

        XCTAssertNil(monitor.mostRecentDisplayTime)
        monitor.recordDisplay(duration: 0.003, presentedAt: 12.5)
        XCTAssertEqual(monitor.mostRecentDisplayTime, 12.5)
    }

    func testCalculatesRatesLatenciesAndRecoveryCounters() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.setSocketReceiveBufferBytes(786_896)
        monitor.recordNetwork(packetCount: 100, byteCount: 1_000_000)
        monitor.recordNetwork(
            packetCount: 0,
            byteCount: 0,
            estimatedSocketBacklogBytes: 32_768,
            receiveDrainDuration: 0.0015
        )
        monitor.recordReceptionReport(
            fractionLost: 64,
            cumulativePacketsLost: 12,
            interarrivalJitterMilliseconds: 1.25
        )
        monitor.recordAccessUnits(240)
        monitor.recordAccessUnitBytes(480_000, intraRefreshCount: 2)
        monitor.recordReceivedFrame(rtpTimestamp: 100)
        monitor.recordReceivedFrame(rtpTimestamp: 100)
        monitor.recordReceivedFrame(rtpTimestamp: 200)
        for _ in 0..<20 {
            monitor.recordRateControlFeedback(
                estimatedBandwidthKilobitsPerSecond: 32_001
            )
        }
        monitor.recordDecode(duration: 0.004)
        monitor.recordDecode(duration: 0.002)
        monitor.recordAccessUnitToDecoderOutput(duration: 0.006)
        monitor.recordAccessUnitToDecoderOutput(duration: 0.004)
        monitor.recordRenderCall(duration: 0.001)
        monitor.recordRenderCall(duration: 0.003)
        for _ in 0..<240 { monitor.recordDecodedFrame() }
        monitor.recordPresentation(latency: 0.008, tileSkew: 0.0015, decodingOrderSpan: 3)
        monitor.recordGPU(duration: 0.0005)
        monitor.recordDisplay(duration: 0.0035, presentedAt: 0.016)
        monitor.recordDisplay(duration: 0.0045, presentedAt: 0.033)
        monitor.recordDisplayLink(lead: 0.004, period: 0.011)
        monitor.recordNACK(count: 2)
        monitor.recordKeyFrameRequest()
        monitor.recordRendererBusy()

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.networkMegabitsPerSecond, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.networkPacketsPerSecond, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.socketReceiveBufferBytes, 786_896)
        XCTAssertEqual(snapshot.maximumSocketBacklogBytes, 32_768)
        XCTAssertEqual(snapshot.maximumReceiveDrainMilliseconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.receiverReportLossPercentage, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.cumulativePacketsLost, 12)
        XCTAssertEqual(snapshot.interarrivalJitterMilliseconds, 1.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.accessUnitsPerSecond, 240, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageAccessUnitKilobytes, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.intraRefreshesPerSecond, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.rateControlFeedbacksPerSecond, 20, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.estimatedReceiveBandwidthMegabitsPerSecond,
            32.001,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.receivedFramesPerSecond, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.decodedFramesPerSecond, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentedFramesPerSecond, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDecodeMilliseconds, 3, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.averageAccessUnitToDecoderOutputMilliseconds,
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.accessUnitToDecoderOutputSampleCount, 2)
        XCTAssertEqual(snapshot.averageRenderCallMilliseconds, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.renderCallSampleCount, 2)
        XCTAssertEqual(snapshot.averagePresentationMilliseconds, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageGPUMilliseconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayedFramesPerSecond, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDisplayMilliseconds, 4, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayCadenceJitterMilliseconds, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDisplayLinkLeadMilliseconds, 4, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.averageDisplayLinkPeriodMilliseconds,
            11,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.maximumTileSkewMilliseconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.maximumDecodingOrderSpan, 3)
        XCTAssertEqual(snapshot.nackCount, 2)
        XCTAssertEqual(snapshot.keyFrameRequestCount, 1)
        XCTAssertEqual(snapshot.rendererBusyCount, 1)
    }

    func testSamplingResetsIntervalValues() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.recordDecodedFrame()
        _ = monitor.sample(at: 1)

        let snapshot = monitor.sample(at: 2)

        XCTAssertEqual(snapshot, .zero)
    }

    func testSocketAndReceptionStatePersistWhileIntervalBacklogResets() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.setSocketReceiveBufferBytes(786_896)
        monitor.recordNetwork(
            packetCount: 1,
            byteCount: 1_000,
            estimatedSocketBacklogBytes: 24_000,
            receiveDrainDuration: 0.002
        )
        monitor.recordReceptionReport(
            fractionLost: 1,
            cumulativePacketsLost: 3,
            interarrivalJitterMilliseconds: 0.5
        )
        _ = monitor.sample(at: 1)

        let snapshot = monitor.sample(at: 2)

        XCTAssertEqual(snapshot.socketReceiveBufferBytes, 786_896)
        XCTAssertEqual(snapshot.maximumSocketBacklogBytes, 0)
        XCTAssertEqual(snapshot.maximumReceiveDrainMilliseconds, 0)
        XCTAssertEqual(snapshot.receiverReportLossPercentage, 100.0 / 256, accuracy: 0.001)
        XCTAssertEqual(snapshot.cumulativePacketsLost, 3)
        XCTAssertEqual(snapshot.interarrivalJitterMilliseconds, 0.5, accuracy: 0.001)
    }

    func testPipelineDiagnosticsAreOptInAndPublishedThroughTheSnapshot() throws {
        let disabled = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false,
            pipelineDiagnosticsEnabled: false
        )
        XCTAssertNil(disabled.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: 0,
            displayPeriod: 1.0 / 120,
            isDisplayLinkTriggered: true
        ))
        XCTAssertEqual(disabled.sample(at: 1).pipelineLatency, .zero)

        let enabled = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false,
            pipelineDiagnosticsEnabled: true
        )
        enabled.recordFrameDelivery(
            frameKey: 1,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0.0005,
            decoderOutputAt: 0.001,
            playbackHandledAt: 0.002,
            mainDeliveredAt: 0.003,
            presentationTime: 0.004
        )
        enabled.recordSchedulerSelection(frameKeys: [1], selectedAt: 0.004)
        let batchID = try XCTUnwrap(enabled.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0.005,
            drawableAcquiredAt: 0.006,
            encodeStartedAt: 0.006,
            encodeEndedAt: 0.007,
            targetTimestamp: 0.010,
            displayPeriod: 0.005,
            isDisplayLinkTriggered: true
        ))
        enabled.recordRenderBatchCommitted(batchID, at: 0.0075)
        enabled.recordRenderBatchScheduled(batchID, at: 0.008)
        enabled.recordRenderBatchCompleted(batchID, gpuStart: 0.008, gpuEnd: 0.009)
        enabled.recordRenderBatchPresented(batchID, at: 0.015)

        let latency = enabled.sample(at: 1).pipelineLatency

        XCTAssertEqual(latency.finalizedBatchCount, 1)
        XCTAssertEqual(latency.decoderSubmitToDisplayMilliseconds.p50, 14.5, accuracy: 0.001)
        XCTAssertEqual(latency.targetPhasePeriods.p50, 1, accuracy: 0.001)
    }

    func testPipelineDiagnosticsCanBeEnabledAndDisabledAtRuntime() throws {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false,
            pipelineDiagnosticsEnabled: false
        )
        XCTAssertNil(monitor.beginRenderBatch(
            frameKeys: [1],
            drawableWaitStartedAt: 0,
            drawableAcquiredAt: 0,
            encodeStartedAt: 0,
            encodeEndedAt: 0,
            targetTimestamp: nil,
            displayPeriod: nil,
            isDisplayLinkTriggered: false
        ))

        monitor.setPipelineDiagnosticsEnabled(true)
        monitor.recordFrameDelivery(
            frameKey: 2,
            accessUnitTiming: nil,
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0.001,
            decoderOutputAt: 0.002,
            playbackHandledAt: 0.003,
            mainDeliveredAt: 0.004,
            presentationTime: 0.005
        )
        monitor.recordSchedulerSelection(frameKeys: [2], selectedAt: 0.006)
        let batchID = try XCTUnwrap(monitor.beginRenderBatch(
            frameKeys: [2],
            drawableWaitStartedAt: 0.007,
            drawableAcquiredAt: 0.007,
            encodeStartedAt: 0.007,
            encodeEndedAt: 0.008,
            targetTimestamp: nil,
            displayPeriod: nil,
            isDisplayLinkTriggered: false
        ))
        monitor.recordRenderBatchCommitted(batchID, at: 0.008)
        monitor.recordRenderBatchScheduled(batchID, at: 0.009)
        monitor.recordRenderBatchCompleted(batchID, gpuStart: 0.009, gpuEnd: 0.010)
        monitor.recordRenderBatchPresented(batchID, at: 0.011)

        XCTAssertEqual(monitor.sample(at: 1).pipelineLatency.finalizedBatchCount, 1)

        monitor.setPipelineDiagnosticsEnabled(false)
        XCTAssertNil(monitor.beginRenderBatch(
            frameKeys: [3],
            drawableWaitStartedAt: 1,
            drawableAcquiredAt: 1,
            encodeStartedAt: 1,
            encodeEndedAt: 1,
            targetTimestamp: nil,
            displayPeriod: nil,
            isDisplayLinkTriggered: false
        ))
        XCTAssertEqual(monitor.sample(at: 2).pipelineLatency, .zero)
    }

    func testDecoderBackendPersistsAcrossSamplesAndCanChange() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.setDecoderBackend(.videoProcessing)

        XCTAssertEqual(monitor.sample(at: 1).decoderBackend, .videoProcessing)
        XCTAssertEqual(monitor.sample(at: 2).decoderBackend, .videoProcessing)

        monitor.setDecoderBackend(.videoToolbox)

        XCTAssertEqual(monitor.sample(at: 3).decoderBackend, .videoToolbox)
    }

    func testMeasuresDisplayedFrameCadenceJitter() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.recordDisplay(duration: 0.003, presentedAt: 1.000)
        monitor.recordDisplay(duration: 0.003, presentedAt: 1.016)
        monitor.recordDisplay(duration: 0.003, presentedAt: 1.033)

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.displayedFramesPerSecond, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDisplayFrameMilliseconds, 16.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.p95DisplayFrameMilliseconds, 17, accuracy: 0.001)
        XCTAssertEqual(snapshot.displayCadenceJitterMilliseconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds.count, 2)
        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds[0], 16, accuracy: 0.001)
        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds[1], 17, accuracy: 0.001)
    }

    func testResetDisplayCadenceStartsASeparateRefreshRateHistory() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.recordDisplay(duration: 0.003, presentedAt: 1.000)
        monitor.recordDisplay(duration: 0.003, presentedAt: 1.007)
        monitor.recordDisplayLink(lead: 0.006, period: 1.0 / 144.0)

        monitor.resetDisplayCadence()
        monitor.recordDisplay(duration: 0.003, presentedAt: 2.000)
        monitor.recordDisplay(duration: 0.003, presentedAt: 2.008)
        monitor.recordDisplayLink(lead: 0.007, period: 1.0 / 120.0)

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds.count, 1)
        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds[0], 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDisplayLinkPeriodMilliseconds, 1000.0 / 120.0, accuracy: 0.001)
    }

    func testCountsSparseTileUpdatesAsSourceFrames() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.recordDecodedFrame(rtpTimestamp: 90_000)
        monitor.recordDecodedFrame(rtpTimestamp: 91_500)
        monitor.recordDecodedFrame(rtpTimestamp: 93_000)

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.decodedFramesPerSecond, 3, accuracy: 0.001)
    }

    func testCountsSharedTimestampTilesAsOneSourceFrame() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        for _ in 0..<4 {
            monitor.recordDecodedFrame(rtpTimestamp: 90_000)
        }

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.decodedFramesPerSecond, 1, accuracy: 0.001)
    }

    func testKeepsOnlyTheMostRecentDisplayFrameTimes() throws {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 1,
            clock: { 0 },
            automaticallyPublishes: false
        )
        for index in 0...130 {
            monitor.recordDisplay(
                duration: 0.003,
                presentedAt: Double(index) * 0.016
            )
        }

        let snapshot = monitor.sample(at: 3)

        XCTAssertEqual(snapshot.recentDisplayFrameMilliseconds.count, 120)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.recentDisplayFrameMilliseconds.first),
            16,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.recentDisplayFrameMilliseconds.last),
            16,
            accuracy: 0.001
        )
    }
}
