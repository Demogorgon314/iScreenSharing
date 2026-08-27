import Combine
import Foundation
import OSLog

struct AppleVideoIngressAgeSnapshot: Equatable, Sendable {
    var p50Milliseconds = 0.0
    var p95Milliseconds = 0.0
    var p99Milliseconds = 0.0
    var maximumMilliseconds = 0.0

    static let zero = AppleVideoIngressAgeSnapshot()
}

struct AppleVideoPerformanceSnapshot: Equatable, Sendable {
    var decoderBackend: AppleHEVCDecoder.Backend? = nil
    var networkMegabitsPerSecond = 0.0
    var networkPacketsPerSecond = 0.0
    var socketReceiveBufferBytes = 0
    var maximumSocketBacklogBytes = 0
    var maximumReceiveDrainMilliseconds = 0.0
    var networkPath = AppleVideoNetworkPath.direct
    var ingressAge = AppleVideoIngressAgeSnapshot.zero
    var receiveBufferOverflowPackets: UInt64 = 0
    var receiverReportLossPercentage = 0.0
    var cumulativePacketsLost: Int32 = 0
    var interarrivalJitterMilliseconds = 0.0
    var accessUnitsPerSecond = 0.0
    var averageAccessUnitKilobytes = 0.0
    var intraRefreshesPerSecond = 0.0
    var rateControlFeedbacksPerSecond = 0.0
    var estimatedReceiveBandwidthMegabitsPerSecond = 0.0
    var receivedFramesPerSecond = 0.0
    var decodedFramesPerSecond = 0.0
    var presentedFramesPerSecond = 0.0
    var averageDecodeMilliseconds = 0.0
    var averageAccessUnitToDecoderOutputMilliseconds = 0.0
    var accessUnitToDecoderOutputSampleCount = 0
    var averageRenderCallMilliseconds = 0.0
    var renderCallSampleCount = 0
    var averagePresentationMilliseconds = 0.0
    var averageGPUMilliseconds = 0.0
    var displayedFramesPerSecond = 0.0
    var averageDisplayMilliseconds = 0.0
    var averageDisplayFrameMilliseconds = 0.0
    var p95DisplayFrameMilliseconds = 0.0
    var displayCadenceJitterMilliseconds = 0.0
    var recentDisplayFrameMilliseconds = [Double]()
    var averageDisplayLinkLeadMilliseconds = 0.0
    var averageDisplayLinkPeriodMilliseconds = 0.0
    var maximumTileSkewMilliseconds = 0.0
    var maximumDecodingOrderSpan = 0
    var nackCount = 0
    var keyFrameRequestCount = 0
    var rendererBusyCount = 0
    var pipelineLatency = AppleVideoPipelineLatencySnapshot.zero

    static let zero = AppleVideoPerformanceSnapshot()
}

final class AppleVideoPerformanceMonitor: ObservableObject, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "VideoPerformance"
    )

    private struct Accumulator {
        var networkPackets = 0
        var networkBytes = 0
        var maximumSocketBacklogBytes = 0
        var maximumReceiveDrainDuration = 0.0
        var receiveBufferOverflowPackets: UInt64 = 0
        var accessUnits = 0
        var accessUnitBytes = 0
        var intraRefreshes = 0
        var rateControlFeedbacks = 0
        var estimatedReceiveBandwidthKilobitsPerSecond: UInt32 = 0
        var receivedSourceTimestamps = Set<UInt32>()
        var decodedSubframes = 0
        var timestampedDecodedSubframes = 0
        var decodedSourceFrames = 0
        var presentedFrames = 0
        var decodeDuration = 0.0
        var decodeSamples = 0
        var accessUnitToDecoderOutputDuration = 0.0
        var accessUnitToDecoderOutputSamples = 0
        var renderCallDuration = 0.0
        var renderCallSamples = 0
        var presentationDuration = 0.0
        var presentationSamples = 0
        var gpuDuration = 0.0
        var gpuSamples = 0
        var displayedFrames = 0
        var displayDuration = 0.0
        var displaySamples = 0
        var displayLinkLead = 0.0
        var displayLinkPeriod = 0.0
        var displayLinkSamples = 0
        var maximumTileSkew = 0.0
        var maximumDecodingOrderSpan = 0
        var nackCount = 0
        var keyFrameRequestCount = 0
        var rendererBusyCount = 0
    }

    @Published private(set) var snapshot = AppleVideoPerformanceSnapshot.zero

    private let tileCount: Int
    private let clock: @Sendable () -> TimeInterval
    private let diagnosticsEnabled: Bool
    private let pipelineDiagnosticsForced: Bool
    private let lock = NSLock()
    private let timer: DispatchSourceTimer?
    private var accumulator = Accumulator()
    private var lastSampleTime: TimeInterval
    private var lastDecodedRTPTimestamp: UInt32?
    private var lastDisplayedTime: TimeInterval?
    private var recentDisplayFrameTimes = [TimeInterval]()
    private var decoderBackend: AppleHEVCDecoder.Backend?
    private var pipelineTrace = AppleVideoPipelineTrace()
    private var pipelineDiagnosticsRequested = false
    private var socketReceiveBufferBytes = 0
    private var networkPath = AppleVideoNetworkPath.direct
    private var ingressAgeSamples = [TimeInterval]()
    private var lastReceiveBufferOverflowCount: UInt64?
    private var receiverReportLossPercentage = 0.0
    private var cumulativePacketsLost: Int32 = 0
    private var interarrivalJitterMilliseconds = 0.0

    private static let displayFrameHistoryLimit = 120

    init(
        tileCount: Int,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticallyPublishes: Bool = true,
        diagnosticsEnabled: Bool = ProcessInfo.processInfo.environment[
            "ISHARESCREEN_FREEZE_DIAGNOSTICS"
        ] == "1",
        pipelineDiagnosticsEnabled: Bool = ProcessInfo.processInfo.environment[
            "ISHARESCREEN_PIPELINE_DIAGNOSTICS"
        ] == "1"
    ) {
        precondition(tileCount > 0)
        self.tileCount = tileCount
        self.clock = clock
        self.diagnosticsEnabled = diagnosticsEnabled
        pipelineDiagnosticsForced = pipelineDiagnosticsEnabled
        lastSampleTime = clock()
        if automaticallyPublishes {
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "com.isharescreen.video-performance", qos: .utility)
            )
            self.timer = timer
            timer.setEventHandler { [weak self] in self?.publishSample() }
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            timer.activate()
        } else {
            timer = nil
        }
    }

    deinit {
        timer?.cancel()
    }

    func setPipelineDiagnosticsEnabled(_ enabled: Bool) {
        lock.withPerformanceLock {
            let wasEnabled = pipelineDiagnosticsAreEnabled
            pipelineDiagnosticsRequested = enabled
            if wasEnabled != pipelineDiagnosticsAreEnabled {
                pipelineTrace.reset()
            }
        }
    }

    func setSocketReceiveBufferBytes(_ byteCount: Int?) {
        lock.withPerformanceLock {
            socketReceiveBufferBytes = max(0, byteCount ?? 0)
        }
    }

    func recordNetwork(
        packetCount: Int,
        byteCount: Int,
        estimatedSocketBacklogBytes: Int = 0,
        receiveDrainDuration: TimeInterval = 0,
        ingressAge: TimeInterval? = nil,
        receiveBufferOverflowCount: UInt64? = nil,
        networkPath: AppleVideoNetworkPath = .direct
    ) {
        lock.withPerformanceLock {
            accumulator.networkPackets += packetCount
            accumulator.networkBytes += byteCount
            accumulator.maximumSocketBacklogBytes = max(
                accumulator.maximumSocketBacklogBytes,
                estimatedSocketBacklogBytes
            )
            accumulator.maximumReceiveDrainDuration = max(
                accumulator.maximumReceiveDrainDuration,
                receiveDrainDuration
            )
            self.networkPath = networkPath
            if let ingressAge, ingressAge.isFinite, ingressAge >= 0 {
                ingressAgeSamples.append(ingressAge)
            }
            if let current = receiveBufferOverflowCount {
                let previous = lastReceiveBufferOverflowCount ?? 0
                let delta = current >= previous ? current - previous : current
                accumulator.receiveBufferOverflowPackets &+= delta
                lastReceiveBufferOverflowCount = current
            }
        }
    }

    func recordReceptionReport(
        fractionLost: UInt8,
        cumulativePacketsLost: Int32,
        interarrivalJitterMilliseconds: Double
    ) {
        lock.withPerformanceLock {
            receiverReportLossPercentage = Double(fractionLost) * 100 / 256
            self.cumulativePacketsLost = cumulativePacketsLost
            self.interarrivalJitterMilliseconds = max(0, interarrivalJitterMilliseconds)
        }
    }

    func recordAccessUnits(_ count: Int) {
        lock.withPerformanceLock { accumulator.accessUnits += count }
    }

    func recordAccessUnitBytes(_ byteCount: Int, intraRefreshCount: Int) {
        lock.withPerformanceLock {
            accumulator.accessUnitBytes += max(0, byteCount)
            accumulator.intraRefreshes += max(0, intraRefreshCount)
        }
    }

    func recordReceivedFrame(rtpTimestamp: UInt32) {
        lock.withPerformanceLock {
            _ = accumulator.receivedSourceTimestamps.insert(rtpTimestamp)
        }
    }

    func recordRateControlFeedback(estimatedBandwidthKilobitsPerSecond: UInt32) {
        lock.withPerformanceLock {
            accumulator.rateControlFeedbacks += 1
            accumulator.estimatedReceiveBandwidthKilobitsPerSecond =
                estimatedBandwidthKilobitsPerSecond
        }
    }

    func recordDecode(duration: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.decodeDuration += max(0, duration)
            accumulator.decodeSamples += 1
        }
    }

    func recordAccessUnitToDecoderOutput(duration: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.accessUnitToDecoderOutputDuration += max(0, duration)
            accumulator.accessUnitToDecoderOutputSamples += 1
        }
    }

    func recordRenderCall(duration: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.renderCallDuration += max(0, duration)
            accumulator.renderCallSamples += 1
        }
    }

    func recordDecodedFrame(rtpTimestamp: UInt32? = nil) {
        lock.withPerformanceLock {
            accumulator.decodedSubframes += 1
            guard let rtpTimestamp else { return }
            accumulator.timestampedDecodedSubframes += 1
            if lastDecodedRTPTimestamp != rtpTimestamp {
                accumulator.decodedSourceFrames += 1
                lastDecodedRTPTimestamp = rtpTimestamp
            }
        }
    }

    func recordPresentation(
        latency: TimeInterval,
        tileSkew: TimeInterval,
        decodingOrderSpan: Int
    ) {
        lock.withPerformanceLock {
            accumulator.presentedFrames += 1
            accumulator.presentationDuration += max(0, latency)
            accumulator.presentationSamples += 1
            accumulator.maximumTileSkew = max(accumulator.maximumTileSkew, tileSkew)
            accumulator.maximumDecodingOrderSpan = max(
                accumulator.maximumDecodingOrderSpan,
                decodingOrderSpan
            )
        }
    }

    func recordGPU(duration: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.gpuDuration += max(0, duration)
            accumulator.gpuSamples += 1
        }
    }

    func recordDisplay(duration: TimeInterval, presentedAt: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.displayedFrames += 1
            accumulator.displayDuration += max(0, duration)
            accumulator.displaySamples += 1
            if let previous = lastDisplayedTime, presentedAt > previous {
                let interval = presentedAt - previous
                recentDisplayFrameTimes.append(interval)
                if recentDisplayFrameTimes.count > Self.displayFrameHistoryLimit {
                    recentDisplayFrameTimes.removeFirst(
                        recentDisplayFrameTimes.count - Self.displayFrameHistoryLimit
                    )
                }
            }
            lastDisplayedTime = presentedAt
        }
    }

    var mostRecentDisplayTime: TimeInterval? {
        lock.withPerformanceLock { lastDisplayedTime }
    }

    func recordDisplayLink(lead: TimeInterval, period: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.displayLinkLead += max(0, lead)
            accumulator.displayLinkPeriod += max(0, period)
            accumulator.displayLinkSamples += 1
        }
    }

    func recordFrameDelivery(
        frameKey: UInt64,
        accessUnitTiming: AppleHEVCAccessUnit.Timing?,
        decodeEnteredAt: TimeInterval,
        decoderSubmittedAt: TimeInterval,
        decoderOutputAt: TimeInterval,
        playbackHandledAt: TimeInterval,
        mainDeliveredAt: TimeInterval,
        presentationTime: TimeInterval
    ) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordFrameDelivery(
                frameKey: frameKey,
                accessUnitTiming: accessUnitTiming,
                decodeEnteredAt: decodeEnteredAt,
                decoderSubmittedAt: decoderSubmittedAt,
                decoderOutputAt: decoderOutputAt,
                playbackHandledAt: playbackHandledAt,
                mainDeliveredAt: mainDeliveredAt,
                presentationTime: presentationTime
            )
        }
    }

    func recordSchedulerSelection(frameKeys: [UInt64], selectedAt: TimeInterval) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordSchedulerSelection(
                frameKeys: frameKeys,
                selectedAt: selectedAt
            )
        }
    }

    func beginRenderBatch(
        frameKeys: [UInt64],
        drawableWaitStartedAt: TimeInterval,
        drawableAcquiredAt: TimeInterval,
        encodeStartedAt: TimeInterval,
        encodeEndedAt: TimeInterval,
        targetTimestamp: TimeInterval?,
        displayPeriod: TimeInterval?,
        isDisplayLinkTriggered: Bool
    ) -> UInt64? {
        return lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return nil }
            return pipelineTrace.beginRenderBatch(
                frameKeys: frameKeys,
                drawableWaitStartedAt: drawableWaitStartedAt,
                drawableAcquiredAt: drawableAcquiredAt,
                encodeStartedAt: encodeStartedAt,
                encodeEndedAt: encodeEndedAt,
                targetTimestamp: targetTimestamp,
                displayPeriod: displayPeriod,
                isDisplayLinkTriggered: isDisplayLinkTriggered
            )
        }
    }

    func recordRenderBatchCommitted(_ batchID: UInt64, at time: TimeInterval) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordCommitted(batchID: batchID, at: time)
        }
    }

    func recordRenderBatchScheduled(_ batchID: UInt64, at time: TimeInterval) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordScheduled(batchID: batchID, at: time)
        }
    }

    func recordRenderBatchCompleted(
        _ batchID: UInt64,
        gpuStart: TimeInterval?,
        gpuEnd: TimeInterval?
    ) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordCompleted(
                batchID: batchID,
                gpuStart: gpuStart,
                gpuEnd: gpuEnd
            )
        }
    }

    func recordRenderBatchPresented(_ batchID: UInt64, at time: TimeInterval) {
        lock.withPerformanceLock {
            guard pipelineDiagnosticsAreEnabled else { return }
            pipelineTrace.recordPresented(batchID: batchID, at: time)
        }
    }

    func resetDisplayCadence() {
        lock.withPerformanceLock {
            lastDisplayedTime = nil
            recentDisplayFrameTimes.removeAll(keepingCapacity: true)
            accumulator.displayLinkLead = 0
            accumulator.displayLinkPeriod = 0
            accumulator.displayLinkSamples = 0
            pipelineTrace.reset()
        }
    }

    func recordNACK(count: Int) {
        lock.withPerformanceLock { accumulator.nackCount += count }
    }

    func recordKeyFrameRequest() {
        lock.withPerformanceLock { accumulator.keyFrameRequestCount += 1 }
    }

    func recordRendererBusy() {
        lock.withPerformanceLock { accumulator.rendererBusyCount += 1 }
    }

    func setDecoderBackend(_ backend: AppleHEVCDecoder.Backend) {
        lock.withPerformanceLock { decoderBackend = backend }
    }

    func sample(at now: TimeInterval) -> AppleVideoPerformanceSnapshot {
        lock.withPerformanceLock {
            let elapsed = max(now - lastSampleTime, 0.000_001)
            let values = accumulator
            let displayFrameTimes = recentDisplayFrameTimes
            let ingressAge = Self.ingressAgeSnapshot(ingressAgeSamples)
            let pipelineLatency = pipelineDiagnosticsAreEnabled
                ? pipelineTrace.sample(at: now)
                : .zero
            accumulator = Accumulator()
            ingressAgeSamples.removeAll(keepingCapacity: true)
            lastSampleTime = now
            return AppleVideoPerformanceSnapshot(
                decoderBackend: decoderBackend,
                networkMegabitsPerSecond: Double(values.networkBytes) * 8 / elapsed / 1_000_000,
                networkPacketsPerSecond: Double(values.networkPackets) / elapsed,
                socketReceiveBufferBytes: socketReceiveBufferBytes,
                maximumSocketBacklogBytes: values.maximumSocketBacklogBytes,
                maximumReceiveDrainMilliseconds: values.maximumReceiveDrainDuration * 1_000,
                networkPath: networkPath,
                ingressAge: ingressAge,
                receiveBufferOverflowPackets: values.receiveBufferOverflowPackets,
                receiverReportLossPercentage: receiverReportLossPercentage,
                cumulativePacketsLost: cumulativePacketsLost,
                interarrivalJitterMilliseconds: interarrivalJitterMilliseconds,
                accessUnitsPerSecond: Double(values.accessUnits) / elapsed,
                averageAccessUnitKilobytes: values.accessUnits > 0
                    ? Double(values.accessUnitBytes) / Double(values.accessUnits) / 1_000
                    : 0,
                intraRefreshesPerSecond: Double(values.intraRefreshes) / elapsed,
                rateControlFeedbacksPerSecond: Double(values.rateControlFeedbacks) / elapsed,
                estimatedReceiveBandwidthMegabitsPerSecond:
                    Double(values.estimatedReceiveBandwidthKilobitsPerSecond) / 1_000,
                receivedFramesPerSecond: Double(values.receivedSourceTimestamps.count) / elapsed,
                decodedFramesPerSecond: Self.decodedFramesPerSecond(
                    values: values,
                    tileCount: tileCount,
                    elapsed: elapsed
                ),
                presentedFramesPerSecond: Double(values.presentedFrames) / elapsed,
                averageDecodeMilliseconds: Self.averageMilliseconds(
                    total: values.decodeDuration,
                    count: values.decodeSamples
                ),
                averageAccessUnitToDecoderOutputMilliseconds: Self.averageMilliseconds(
                    total: values.accessUnitToDecoderOutputDuration,
                    count: values.accessUnitToDecoderOutputSamples
                ),
                accessUnitToDecoderOutputSampleCount: values.accessUnitToDecoderOutputSamples,
                averageRenderCallMilliseconds: Self.averageMilliseconds(
                    total: values.renderCallDuration,
                    count: values.renderCallSamples
                ),
                renderCallSampleCount: values.renderCallSamples,
                averagePresentationMilliseconds: Self.averageMilliseconds(
                    total: values.presentationDuration,
                    count: values.presentationSamples
                ),
                averageGPUMilliseconds: Self.averageMilliseconds(
                    total: values.gpuDuration,
                    count: values.gpuSamples
                ),
                displayedFramesPerSecond: Double(values.displayedFrames) / elapsed,
                averageDisplayMilliseconds: Self.averageMilliseconds(
                    total: values.displayDuration,
                    count: values.displaySamples
                ),
                averageDisplayFrameMilliseconds: Self.averageMilliseconds(
                    values: displayFrameTimes
                ),
                p95DisplayFrameMilliseconds: Self.percentileMilliseconds(
                    values: displayFrameTimes,
                    percentile: 0.95
                ),
                displayCadenceJitterMilliseconds: Self.standardDeviationMilliseconds(
                    values: displayFrameTimes
                ),
                recentDisplayFrameMilliseconds: displayFrameTimes.map { $0 * 1_000 },
                averageDisplayLinkLeadMilliseconds: Self.averageMilliseconds(
                    total: values.displayLinkLead,
                    count: values.displayLinkSamples
                ),
                averageDisplayLinkPeriodMilliseconds: Self.averageMilliseconds(
                    total: values.displayLinkPeriod,
                    count: values.displayLinkSamples
                ),
                maximumTileSkewMilliseconds: values.maximumTileSkew * 1_000,
                maximumDecodingOrderSpan: values.maximumDecodingOrderSpan,
                nackCount: values.nackCount,
                keyFrameRequestCount: values.keyFrameRequestCount,
                rendererBusyCount: values.rendererBusyCount,
                pipelineLatency: pipelineLatency
            )
        }
    }

    private func publishSample() {
        let next = sample(at: clock())
#if DEBUG
        let shouldLogDiagnostics = true
#else
        let shouldLogDiagnostics = diagnosticsEnabled
#endif
        if shouldLogDiagnostics {
            Self.logger.notice(
                "[DEBUG-NET-27C4] net=\(next.networkMegabitsPerSecond, format: .fixed(precision: 1))Mbps packets=\(next.networkPacketsPerSecond, format: .fixed(precision: 1))/s path=\(next.networkPath.rawValue, privacy: .public) rcvbuf=\(next.socketReceiveBufferBytes)B backlog=\(next.maximumSocketBacklogBytes)B drain=\(next.maximumReceiveDrainMilliseconds, format: .fixed(precision: 2))ms ingress=\(next.ingressAge.p50Milliseconds, format: .fixed(precision: 2))/\(next.ingressAge.p95Milliseconds, format: .fixed(precision: 2))/\(next.ingressAge.p99Milliseconds, format: .fixed(precision: 2))/\(next.ingressAge.maximumMilliseconds, format: .fixed(precision: 2))ms overflow=\(next.receiveBufferOverflowPackets) rrLoss=\(next.receiverReportLossPercentage, format: .fixed(precision: 2))% cumulativeLost=\(next.cumulativePacketsLost) rrJitter=\(next.interarrivalJitterMilliseconds, format: .fixed(precision: 2))ms"
            )
            Self.logger.notice(
                "[DEBUG-TEAR-8A7C] stream=\(next.accessUnitsPerSecond, format: .fixed(precision: 1))AU/s auKB=\(next.averageAccessUnitKilobytes, format: .fixed(precision: 2)) irap=\(next.intraRefreshesPerSecond, format: .fixed(precision: 1))/s rctl=\(next.rateControlFeedbacksPerSecond, format: .fixed(precision: 1))/s bwe=\(next.estimatedReceiveBandwidthMegabitsPerSecond, format: .fixed(precision: 1))Mbps decode=\(next.decodedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averageDecodeMilliseconds, format: .fixed(precision: 2))ms submit=\(next.presentedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averagePresentationMilliseconds, format: .fixed(precision: 2))ms display=\(next.displayedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averageDisplayMilliseconds, format: .fixed(precision: 2))ms frame=\(next.averageDisplayFrameMilliseconds, format: .fixed(precision: 2))ms p95=\(next.p95DisplayFrameMilliseconds, format: .fixed(precision: 2))ms jitter=\(next.displayCadenceJitterMilliseconds, format: .fixed(precision: 2))ms lead=\(next.averageDisplayLinkLeadMilliseconds, format: .fixed(precision: 2))ms period=\(next.averageDisplayLinkPeriodMilliseconds, format: .fixed(precision: 2))ms tile=\(next.maximumTileSkewMilliseconds, format: .fixed(precision: 2))ms don=\(next.maximumDecodingOrderSpan) nack=\(next.nackCount) fir=\(next.keyFrameRequestCount) busy=\(next.rendererBusyCount)"
            )
        }
        if pipelineDiagnosticsAreEnabledNow {
            Self.logPipelineDiagnostics(next.pipelineLatency)
        }
        DispatchQueue.main.async { [weak self] in self?.snapshot = next }
    }

    private static func logPipelineDiagnostics(_ latency: AppleVideoPipelineLatencySnapshot) {
        logger.notice(
            "[DEBUG-PIPE-A17E] ingress datagramSpan=\(latency.datagramSpanMilliseconds.p50, format: .fixed(precision: 2))/\(latency.datagramSpanMilliseconds.p95, format: .fixed(precision: 2))ms assemble=\(latency.completingDatagramToAssemblyMilliseconds.p50, format: .fixed(precision: 2))/\(latency.completingDatagramToAssemblyMilliseconds.p95, format: .fixed(precision: 2))ms auDecode=\(latency.assemblyToDecodeEntryMilliseconds.p50, format: .fixed(precision: 2))/\(latency.assemblyToDecodeEntryMilliseconds.p95, format: .fixed(precision: 2))ms prepare=\(latency.decodeEntryToSubmitMilliseconds.p50, format: .fixed(precision: 2))/\(latency.decodeEntryToSubmitMilliseconds.p95, format: .fixed(precision: 2))ms decoder=\(latency.decoderSubmitToCallbackMilliseconds.p50, format: .fixed(precision: 2))/\(latency.decoderSubmitToCallbackMilliseconds.p95, format: .fixed(precision: 2))ms"
        )
        logger.notice(
            "[DEBUG-PIPE-A17E] delivery cbPb=\(latency.decoderCallbackToPlaybackMilliseconds.p50, format: .fixed(precision: 2))/\(latency.decoderCallbackToPlaybackMilliseconds.p95, format: .fixed(precision: 2))/\(latency.decoderCallbackToPlaybackMilliseconds.maximum, format: .fixed(precision: 2))ms pbMain=\(latency.playbackToMainMilliseconds.p50, format: .fixed(precision: 2))/\(latency.playbackToMainMilliseconds.p95, format: .fixed(precision: 2))/\(latency.playbackToMainMilliseconds.maximum, format: .fixed(precision: 2))ms mainSel=\(latency.mainToSchedulerMilliseconds.p50, format: .fixed(precision: 2))/\(latency.mainToSchedulerMilliseconds.p95, format: .fixed(precision: 2))/\(latency.mainToSchedulerMilliseconds.maximum, format: .fixed(precision: 2))ms"
        )
        logger.notice(
            "[DEBUG-PIPE-A17E] render selDraw=\(latency.schedulerToDrawableMilliseconds.p50, format: .fixed(precision: 2))/\(latency.schedulerToDrawableMilliseconds.p95, format: .fixed(precision: 2))/\(latency.schedulerToDrawableMilliseconds.maximum, format: .fixed(precision: 2))ms drawable=\(latency.drawableWaitMilliseconds.p50, format: .fixed(precision: 2))/\(latency.drawableWaitMilliseconds.p95, format: .fixed(precision: 2))/\(latency.drawableWaitMilliseconds.maximum, format: .fixed(precision: 2))ms encode=\(latency.encodeMilliseconds.p50, format: .fixed(precision: 2))/\(latency.encodeMilliseconds.p95, format: .fixed(precision: 2))/\(latency.encodeMilliseconds.maximum, format: .fixed(precision: 2))ms traceCommit=\(latency.encodeEndToCommitMilliseconds.p95, format: .fixed(precision: 2))ms"
        )
        logger.notice(
            "[DEBUG-PIPE-A17E] metal scheduledCallback=\(latency.commitToScheduledCallbackMilliseconds.p95, format: .fixed(precision: 2))ms gpuQueue=\(latency.gpuQueueWaitMilliseconds.p95, format: .fixed(precision: 2))ms gpuExec=\(latency.gpuExecutionMilliseconds.p95, format: .fixed(precision: 2))ms gpuDisplay=\(latency.gpuEndToDisplayMilliseconds.p95, format: .fixed(precision: 2))ms commitDisplay=\(latency.commitToDisplayMilliseconds.p95, format: .fixed(precision: 2))ms"
        )
        logger.notice(
            "[DEBUG-PIPE-A17E] target schedulerLead=\(latency.schedulerToTargetMilliseconds.minimum, format: .fixed(precision: 2))/\(latency.schedulerToTargetMilliseconds.p50, format: .fixed(precision: 2))ms ptsLead=\(latency.presentationToTargetMilliseconds.minimum, format: .fixed(precision: 2))/\(latency.presentationToTargetMilliseconds.p50, format: .fixed(precision: 2))ms commitLead=\(latency.commitLeadToTargetMilliseconds.minimum, format: .fixed(precision: 2))/\(latency.commitLeadToTargetMilliseconds.p50, format: .fixed(precision: 2))ms gpuLead=\(latency.gpuEndLeadToTargetMilliseconds.minimum, format: .fixed(precision: 2))/\(latency.gpuEndLeadToTargetMilliseconds.p50, format: .fixed(precision: 2))ms displayPhase=\(latency.targetToDisplayMilliseconds.p50, format: .fixed(precision: 2))/\(latency.targetToDisplayMilliseconds.p95, format: .fixed(precision: 2))ms phasePeriods=\(latency.targetPhasePeriods.p50, format: .fixed(precision: 2))/\(latency.targetPhasePeriods.p95, format: .fixed(precision: 2)) misses=\(latency.displayLinkMissCount)"
        )
        logger.notice(
            "[DEBUG-PIPE-A17E] result firstDatagramEnd=\(latency.firstDatagramToDisplayMilliseconds.p50, format: .fixed(precision: 2))/\(latency.firstDatagramToDisplayMilliseconds.p95, format: .fixed(precision: 2))/\(latency.firstDatagramToDisplayMilliseconds.maximum, format: .fixed(precision: 2))ms submitEnd=\(latency.decoderSubmitToDisplayMilliseconds.p50, format: .fixed(precision: 2))/\(latency.decoderSubmitToDisplayMilliseconds.p95, format: .fixed(precision: 2))/\(latency.decoderSubmitToDisplayMilliseconds.maximum, format: .fixed(precision: 2))ms callbackEnd=\(latency.decoderCallbackToDisplayMilliseconds.p50, format: .fixed(precision: 2))/\(latency.decoderCallbackToDisplayMilliseconds.p95, format: .fixed(precision: 2))/\(latency.decoderCallbackToDisplayMilliseconds.maximum, format: .fixed(precision: 2))ms immediateAge=\(latency.immediatePreviousTargetAgeMilliseconds.p95, format: .fixed(precision: 2))ms batches=\(latency.displayLinkBatchCount)/\(latency.immediateBatchCount)/\(latency.finalizedBatchCount) evict=\(latency.traceEvictionCount)"
        )
    }

    private var pipelineDiagnosticsAreEnabled: Bool {
        pipelineDiagnosticsForced || pipelineDiagnosticsRequested
    }

    private var pipelineDiagnosticsAreEnabledNow: Bool {
        lock.withPerformanceLock { pipelineDiagnosticsAreEnabled }
    }

    private static func averageMilliseconds(total: TimeInterval, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return total / Double(count) * 1_000
    }

    private static func decodedFramesPerSecond(
        values: Accumulator,
        tileCount: Int,
        elapsed: TimeInterval
    ) -> Double {
        if values.timestampedDecodedSubframes > 0 {
            return Double(values.decodedSourceFrames) / elapsed
        }
        return Double(values.decodedSubframes) / Double(tileCount) / elapsed
    }

    private static func averageMilliseconds(values: [TimeInterval]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count) * 1_000
    }

    private static func percentileMilliseconds(
        values: [TimeInterval],
        percentile: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[rank] * 1_000
    }

    private static func ingressAgeSnapshot(
        _ samples: [TimeInterval]
    ) -> AppleVideoIngressAgeSnapshot {
        guard !samples.isEmpty else { return .zero }
        let sorted = samples.sorted()
        func percentile(_ value: Double) -> Double {
            let rank = max(
                0,
                min(sorted.count - 1, Int(ceil(value * Double(sorted.count))) - 1)
            )
            return sorted[rank] * 1_000
        }
        return AppleVideoIngressAgeSnapshot(
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99),
            maximumMilliseconds: sorted[sorted.count - 1] * 1_000
        )
    }

    private static func standardDeviationMilliseconds(values: [TimeInterval]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let squaredTotal = values.reduce(0) { result, value in
            let difference = value - mean
            return result + difference * difference
        }
        let variance = squaredTotal / Double(values.count)
        return variance.squareRoot() * 1_000
    }
}

private extension NSLock {
    func withPerformanceLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
