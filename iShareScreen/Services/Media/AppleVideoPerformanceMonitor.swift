import Combine
import Foundation

struct AppleVideoPerformanceSnapshot: Equatable, Sendable {
    var networkMegabitsPerSecond = 0.0
    var networkPacketsPerSecond = 0.0
    var accessUnitsPerSecond = 0.0
    var decodedFramesPerSecond = 0.0
    var presentedFramesPerSecond = 0.0
    var averageDecodeMilliseconds = 0.0
    var averagePresentationMilliseconds = 0.0
    var averageGPUMilliseconds = 0.0
    var maximumTileSkewMilliseconds = 0.0
    var maximumDecodingOrderSpan = 0
    var nackCount = 0
    var keyFrameRequestCount = 0
    var rendererBusyCount = 0

    static let zero = AppleVideoPerformanceSnapshot()
}

final class AppleVideoPerformanceMonitor: ObservableObject, @unchecked Sendable {
    private struct Accumulator {
        var networkPackets = 0
        var networkBytes = 0
        var accessUnits = 0
        var decodedSubframes = 0
        var presentedFrames = 0
        var decodeDuration = 0.0
        var decodeSamples = 0
        var presentationDuration = 0.0
        var presentationSamples = 0
        var gpuDuration = 0.0
        var gpuSamples = 0
        var maximumTileSkew = 0.0
        var maximumDecodingOrderSpan = 0
        var nackCount = 0
        var keyFrameRequestCount = 0
        var rendererBusyCount = 0
    }

    @Published private(set) var snapshot = AppleVideoPerformanceSnapshot.zero

    private let tileCount: Int
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let timer: DispatchSourceTimer?
    private var accumulator = Accumulator()
    private var lastSampleTime: TimeInterval

    init(
        tileCount: Int,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticallyPublishes: Bool = true
    ) {
        precondition(tileCount > 0)
        self.tileCount = tileCount
        self.clock = clock
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

    func recordDecode(duration: TimeInterval) {
        lock.withPerformanceLock {
            accumulator.decodeDuration += max(0, duration)
            accumulator.decodeSamples += 1
        }
    }

    func recordDecodedFrame() {
        lock.withPerformanceLock { accumulator.decodedSubframes += 1 }
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

    func recordNACK(count: Int) {
        lock.withPerformanceLock { accumulator.nackCount += count }
    }

    func recordKeyFrameRequest() {
        lock.withPerformanceLock { accumulator.keyFrameRequestCount += 1 }
    }

    func recordRendererBusy() {
        lock.withPerformanceLock { accumulator.rendererBusyCount += 1 }
    }

    func sample(at now: TimeInterval) -> AppleVideoPerformanceSnapshot {
        lock.withPerformanceLock {
            let elapsed = max(now - lastSampleTime, 0.000_001)
            let values = accumulator
            accumulator = Accumulator()
            lastSampleTime = now
            return AppleVideoPerformanceSnapshot(
                networkMegabitsPerSecond: Double(values.networkBytes) * 8 / elapsed / 1_000_000,
                networkPacketsPerSecond: Double(values.networkPackets) / elapsed,
                accessUnitsPerSecond: Double(values.accessUnits) / elapsed,
                decodedFramesPerSecond: Double(values.decodedSubframes) / Double(tileCount) / elapsed,
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
        DispatchQueue.main.async { [weak self] in self?.snapshot = next }
    }

    private static func averageMilliseconds(total: TimeInterval, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return total / Double(count) * 1_000
    }
}

private extension NSLock {
    func withPerformanceLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
