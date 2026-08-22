import XCTest
@testable import iShareScreen

final class AppleVideoPerformanceMonitorTests: XCTestCase {
    func testCalculatesRatesLatenciesAndRecoveryCounters() {
        let monitor = AppleVideoPerformanceMonitor(
            tileCount: 4,
            clock: { 0 },
            automaticallyPublishes: false
        )
        monitor.recordNetwork(packetCount: 100, byteCount: 1_000_000)
        monitor.recordAccessUnits(240)
        monitor.recordDecode(duration: 0.004)
        monitor.recordDecode(duration: 0.002)
        for _ in 0..<240 { monitor.recordDecodedFrame() }
        monitor.recordPresentation(latency: 0.008, tileSkew: 0.0015, decodingOrderSpan: 3)
        monitor.recordGPU(duration: 0.0005)
        monitor.recordNACK(count: 2)
        monitor.recordKeyFrameRequest()
        monitor.recordRendererBusy()

        let snapshot = monitor.sample(at: 1)

        XCTAssertEqual(snapshot.networkMegabitsPerSecond, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.networkPacketsPerSecond, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.accessUnitsPerSecond, 240, accuracy: 0.001)
        XCTAssertEqual(snapshot.decodedFramesPerSecond, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.presentedFramesPerSecond, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageDecodeMilliseconds, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.averagePresentationMilliseconds, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageGPUMilliseconds, 0.5, accuracy: 0.001)
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
}
