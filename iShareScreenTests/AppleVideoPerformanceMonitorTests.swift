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
        monitor.recordDisplay(duration: 0.0035, presentedAt: 0.016)
        monitor.recordDisplay(duration: 0.0045, presentedAt: 0.033)
        monitor.recordDisplayLink(lead: 0.004, period: 0.011)
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
