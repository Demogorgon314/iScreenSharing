import Combine
import Foundation
import OSLog

struct AppleVideoPerformanceSnapshot: Equatable, Sendable {
    var decoderBackend: AppleHEVCDecoder.Backend? = nil
    var networkMegabitsPerSecond = 0.0
    var networkPacketsPerSecond = 0.0
    var accessUnitsPerSecond = 0.0
    var averageAccessUnitKilobytes = 0.0
    var intraRefreshesPerSecond = 0.0
    var rateControlFeedbacksPerSecond = 0.0
    var estimatedReceiveBandwidthMegabitsPerSecond = 0.0
    var decodedFramesPerSecond = 0.0
    var presentedFramesPerSecond = 0.0
    var averageDecodeMilliseconds = 0.0
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
        var accessUnits = 0
        var accessUnitBytes = 0
        var intraRefreshes = 0
        var rateControlFeedbacks = 0
        var estimatedReceiveBandwidthKilobitsPerSecond: UInt32 = 0
        var decodedSubframes = 0
        var timestampedDecodedSubframes = 0
        var decodedSourceFrames = 0
        var presentedFrames = 0
        var decodeDuration = 0.0
        var decodeSamples = 0
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
    private let lock = NSLock()
    private let timer: DispatchSourceTimer?
    private var accumulator = Accumulator()
    private var lastSampleTime: TimeInterval
    private var lastDecodedRTPTimestamp: UInt32?
    private var lastDisplayedTime: TimeInterval?
    private var recentDisplayFrameTimes = [TimeInterval]()
    private var decoderBackend: AppleHEVCDecoder.Backend?

    private static let displayFrameHistoryLimit = 120

    init(
        tileCount: Int,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticallyPublishes: Bool = true,
        diagnosticsEnabled: Bool = ProcessInfo.processInfo.environment[
            "ISHARESCREEN_FREEZE_DIAGNOSTICS"
        ] == "1"
    ) {
        precondition(tileCount > 0)
        self.tileCount = tileCount
        self.clock = clock
        self.diagnosticsEnabled = diagnosticsEnabled
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

    func recordNetwork(packetCount: Int, byteCount: Int) {
        lock.withPerformanceLock {
            accumulator.networkPackets += packetCount
            accumulator.networkBytes += byteCount
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
            accumulator = Accumulator()
            lastSampleTime = now
            return AppleVideoPerformanceSnapshot(
                decoderBackend: decoderBackend,
                networkMegabitsPerSecond: Double(values.networkBytes) * 8 / elapsed / 1_000_000,
                networkPacketsPerSecond: Double(values.networkPackets) / elapsed,
                accessUnitsPerSecond: Double(values.accessUnits) / elapsed,
                averageAccessUnitKilobytes: values.accessUnits > 0
                    ? Double(values.accessUnitBytes) / Double(values.accessUnits) / 1_000
                    : 0,
                intraRefreshesPerSecond: Double(values.intraRefreshes) / elapsed,
                rateControlFeedbacksPerSecond: Double(values.rateControlFeedbacks) / elapsed,
                estimatedReceiveBandwidthMegabitsPerSecond:
                    Double(values.estimatedReceiveBandwidthKilobitsPerSecond) / 1_000,
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
                rendererBusyCount: values.rendererBusyCount
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
            "[DEBUG-TEAR-8A7C] net=\(next.networkMegabitsPerSecond, format: .fixed(precision: 1))Mbps packets=\(next.networkPacketsPerSecond, format: .fixed(precision: 1))/s stream=\(next.accessUnitsPerSecond, format: .fixed(precision: 1))AU/s auKB=\(next.averageAccessUnitKilobytes, format: .fixed(precision: 2)) irap=\(next.intraRefreshesPerSecond, format: .fixed(precision: 1))/s rctl=\(next.rateControlFeedbacksPerSecond, format: .fixed(precision: 1))/s bwe=\(next.estimatedReceiveBandwidthMegabitsPerSecond, format: .fixed(precision: 1))Mbps decode=\(next.decodedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averageDecodeMilliseconds, format: .fixed(precision: 2))ms submit=\(next.presentedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averagePresentationMilliseconds, format: .fixed(precision: 2))ms display=\(next.displayedFramesPerSecond, format: .fixed(precision: 1))fps/\(next.averageDisplayMilliseconds, format: .fixed(precision: 2))ms frame=\(next.averageDisplayFrameMilliseconds, format: .fixed(precision: 2))ms p95=\(next.p95DisplayFrameMilliseconds, format: .fixed(precision: 2))ms jitter=\(next.displayCadenceJitterMilliseconds, format: .fixed(precision: 2))ms lead=\(next.averageDisplayLinkLeadMilliseconds, format: .fixed(precision: 2))ms period=\(next.averageDisplayLinkPeriodMilliseconds, format: .fixed(precision: 2))ms tile=\(next.maximumTileSkewMilliseconds, format: .fixed(precision: 2))ms don=\(next.maximumDecodingOrderSpan) nack=\(next.nackCount) fir=\(next.keyFrameRequestCount) busy=\(next.rendererBusyCount)"
            )
        }
        DispatchQueue.main.async { [weak self] in self?.snapshot = next }
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
