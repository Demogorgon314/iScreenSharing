import XCTest
@testable import iScreenSharing

final class AppleVideoRateControlTests: XCTestCase {
    func testRateControlModeDefaultsToEstimated() {
        XCTAssertEqual(AppleVideoRateControlMode(environmentValue: nil), .estimated)
        XCTAssertEqual(AppleVideoRateControlMode(environmentValue: "unknown"), .estimated)
    }

    func testFixedLANRateControlModeOverridesOnlyCapacitySignals() throws {
        let original = AppleVideoRateControlInfo(
            rtpTimestamp: 123,
            estimatedBandwidthKilobitsPerSecond: 4_000,
            burstyLoss: 2,
            receivedPacketCount: 456,
            feedbackDelayMilliseconds: 7,
            echoTimestamp: 8,
            oneWayReceiveDelay: 0.25
        )

        let overridden = try XCTUnwrap(
            AppleVideoRateControlMode(environmentValue: "FIXED-LAN").apply(to: original)
        )
        XCTAssertEqual(overridden.rtpTimestamp, original.rtpTimestamp)
        XCTAssertEqual(overridden.estimatedBandwidthKilobitsPerSecond, 60_001)
        XCTAssertEqual(overridden.burstyLoss, original.burstyLoss)
        XCTAssertEqual(overridden.receivedPacketCount, original.receivedPacketCount)
        XCTAssertEqual(overridden.feedbackDelayMilliseconds, original.feedbackDelayMilliseconds)
        XCTAssertEqual(overridden.echoTimestamp, original.echoTimestamp)
        XCTAssertEqual(overridden.oneWayReceiveDelay, 0)
    }

    func testDisabledRateControlModeSuppressesFeedback() {
        let info = AppleVideoRateControlInfo(
            rtpTimestamp: 1,
            estimatedBandwidthKilobitsPerSecond: 2,
            burstyLoss: 0,
            receivedPacketCount: 3,
            feedbackDelayMilliseconds: 4,
            echoTimestamp: 5,
            oneWayReceiveDelay: 0
        )

        XCTAssertNil(AppleVideoRateControlMode(environmentValue: "disabled").apply(to: info))
    }

    func testSerializesNativeGoldenVector() {
        let feedback = AppleVideoRateControlInfo(
            rtpTimestamp: 106_500,
            estimatedBandwidthKilobitsPerSecond: 32_001,
            burstyLoss: 0,
            receivedPacketCount: 67,
            feedbackDelayMilliseconds: 66,
            echoTimestamp: AppleVideoRateControlInfo.echoTimestamp(at: 1_000.25),
            oneWayReceiveDelay: 0
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "85000004a004000000000042a100000000437d01"
        )
    }

    func testClampsBoundedFieldsAndPacksDelay() throws {
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 1,
            estimatedBandwidthKilobitsPerSecond: 2,
            burstyLoss: 20,
            receivedPacketCount: 0x1abc,
            feedbackDelayMilliseconds: UInt32.max,
            echoTimestamp: 3,
            oneWayReceiveDelay: 0.5
        ).serialized()

        XCTAssertEqual(try payload.uint16BE(at: 10), UInt16.max)
        XCTAssertEqual(try payload.uint16BE(at: 14), 4_096)
        XCTAssertEqual(try payload.uint16BE(at: 16), 0xfabc)
    }

    func testInvalidTimesDegradeToZero() throws {
        XCTAssertEqual(AppleVideoRateControlInfo.echoTimestamp(at: -.infinity), 0)
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 0,
            estimatedBandwidthKilobitsPerSecond: 0,
            burstyLoss: 0,
            receivedPacketCount: 0,
            feedbackDelayMilliseconds: 0,
            echoTimestamp: 0,
            oneWayReceiveDelay: .nan
        ).serialized()
        XCTAssertEqual(try payload.uint16BE(at: 14), 0)
    }

    func testStableProbeSequenceMatchesNativeGoldenVector() throws {
        let feedback = try XCTUnwrap(
            estimate(spacing: 0.0003).feedback(at: 1_002.05)
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "8500000418d4000000000042a833000002cb7d01"
        )
    }

    func testFastProbeSequenceClampsAtNativeMaximumBandwidth() throws {
        let feedback = try XCTUnwrap(
            estimate(spacing: 0.0001).feedback(at: 1_002.05)
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "8500000418d4000000000042a833000002cbea61"
        )
    }

    func testSparseProbeChangesBandwidthWithoutInventingBurstyLoss() throws {
        let feedback = try XCTUnwrap(
            estimate(spacing: 0.0003, packetIndexes: [0, 1, 4, 5])
                .feedback(at: 1_002.05)
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "8500000418d4000000000042a833000001dd4b01"
        )
    }

    func testOldTimestampDoesNotMovePlayoutStatistics() throws {
        let feedback = try XCTUnwrap(
            estimate(spacing: 0.0003, insertsOldTimestamp: true)
                .feedback(at: 1_002.05)
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "8500000418d4000000000042a833000002cc7d01"
        )
    }

    func testFeedbackPersistsWhileVideoIsIdleAndOnlyAgeChanges() throws {
        let estimator = estimate(spacing: 0.0003)
        let recent = try XCTUnwrap(estimator.feedback(at: 1_002.05)).serialized()
        let idle = try XCTUnwrap(estimator.feedback(at: 1_007.05)).serialized()

        XCTAssertEqual(try recent.uint16BE(at: 10), 66)
        XCTAssertEqual(try idle.uint16BE(at: 10), 5_066)
        XCTAssertEqual(recent.prefix(10), idle.prefix(10))
        XCTAssertEqual(recent.suffix(6), idle.suffix(6))
    }

    func testNativeProbeGateSuppressesPacketsForTwoSecondsAfterMarker() {
        var gate = AppleVideoBandwidthProbeGate()
        let fragment = Data([0x62, 0x01, 0x01, 0x00])
        let singleNAL = Data([0x26, 0x01, 0x00, 0x01])

        XCTAssertEqual(
            gate.classify(
                timestamp: 100,
                arrivalTime: 10,
                isEndOfFrame: false,
                payload: fragment
            ),
            .active
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 100,
                arrivalTime: 10.005,
                isEndOfFrame: true,
                payload: singleNAL
            ),
            .active
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 200,
                arrivalTime: 11,
                isEndOfFrame: true,
                payload: fragment
            ),
            .suppressed
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 300,
                arrivalTime: 12.005,
                isEndOfFrame: false,
                payload: fragment
            ),
            .active
        )
    }

    func testNativeProbeGateEmitsInactiveBoundaryForUnrecognizedNewTimestamp() {
        var gate = AppleVideoBandwidthProbeGate()
        let fragment = Data([0x62, 0x01, 0x01, 0x00])
        let singleNAL = Data([0x26, 0x01, 0x00, 0x01])

        XCTAssertEqual(
            gate.classify(
                timestamp: 100,
                arrivalTime: 10,
                isEndOfFrame: false,
                payload: fragment
            ),
            .active
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 101,
                arrivalTime: 10.005,
                isEndOfFrame: false,
                payload: singleNAL
            ),
            .boundary
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 102,
                arrivalTime: 12.004,
                isEndOfFrame: false,
                payload: fragment
            ),
            .suppressed
        )
        XCTAssertEqual(
            gate.classify(
                timestamp: 103,
                arrivalTime: 12.005,
                isEndOfFrame: false,
                payload: fragment
            ),
            .active
        )
    }

    func testSuppressedProbePacketsDoNotChangeBandwidthEstimate() throws {
        var estimator = AppleVideoRateControlEstimator()
        let firstTimestamp: UInt32 = 24_000
        for packetIndex in 0..<6 {
            estimator.observe(
                AppleVideoPacketObservation(
                    rtpTimestamp: firstTimestamp,
                    arrivalTime: 1_000 + Double(packetIndex) * 0.001,
                    packetSize: 1_200
                ),
                bandwidthProbeActivity: .active
            )
        }
        estimator.observe(
            AppleVideoPacketObservation(
                rtpTimestamp: firstTimestamp + 400,
                arrivalTime: 1_002,
                packetSize: 1_200
            ),
            bandwidthProbeActivity: .boundary
        )
        let initialBandwidth = try bandwidth(in: estimator)

        for frame in 2..<120 {
            estimator.observe(
                AppleVideoPacketObservation(
                    rtpTimestamp: firstTimestamp + UInt32(frame * 400),
                    arrivalTime: 1_002 + Double(frame) / 60,
                    packetSize: 400
                ),
                bandwidthProbeActivity: .suppressed
            )
        }

        XCTAssertEqual(try bandwidth(in: estimator), initialBandwidth)
    }

    func testRequiresThreeProbeGroupsBeforeCommittingSuddenBandwidthChange() throws {
        var estimator = AppleVideoRateControlEstimator()
        feedGroup(&estimator, frame: 0, spacing: 0.0003, packetCount: 33)
        feedGroup(&estimator, frame: 1, spacing: 0.0003, packetCount: 33)
        feedGroup(&estimator, frame: 2, spacing: 0.002)
        XCTAssertEqual(try bandwidth(in: estimator), 32_001)

        feedGroup(&estimator, frame: 3, spacing: 0.002)
        XCTAssertEqual(try bandwidth(in: estimator), 32_000)
        feedGroup(&estimator, frame: 4, spacing: 0.002)
        XCTAssertEqual(try bandwidth(in: estimator), 32_000)
        feedGroup(&estimator, frame: 5, spacing: 0.002)
        XCTAssertEqual(try bandwidth(in: estimator), 4_800)
        feedGroup(&estimator, frame: 6, spacing: 0.002)
        XCTAssertEqual(try bandwidth(in: estimator), 4_801)
    }

    func testAlternatingSuddenChangesNeverCommit() throws {
        var estimator = AppleVideoRateControlEstimator()
        feedGroup(&estimator, frame: 0, spacing: 0.0003, packetCount: 33)
        feedGroup(&estimator, frame: 1, spacing: 0.0003, packetCount: 33)

        for frame in 2..<12 {
            let spacing = frame.isMultiple(of: 2) ? 0.002 : 0.0001
            feedGroup(&estimator, frame: frame, spacing: spacing)
        }

        XCTAssertEqual(try bandwidth(in: estimator), 32_000)
    }

    func testShortProbeWindowsRequireBothNativeConfirmationStages() throws {
        var estimator = AppleVideoRateControlEstimator()
        for frame in 0..<5 {
            feedGroup(
                &estimator,
                frame: frame,
                spacing: 0.0003,
                packetCount: 33
            )
        }
        XCTAssertEqual(try bandwidth(in: estimator), 32_001)

        feedGroup(&estimator, frame: 5, spacing: 0.0014)
        feedGroup(&estimator, frame: 6, spacing: 0.0014)
        XCTAssertEqual(try bandwidth(in: estimator), 32_000)

        feedGroup(&estimator, frame: 7, spacing: 0.0014)
        feedGroup(&estimator, frame: 8, spacing: 0.0014)
        feedGroup(&estimator, frame: 9, spacing: 0.0014)
        XCTAssertEqual(try bandwidth(in: estimator), 32_000)

        feedGroup(&estimator, frame: 10, spacing: 0.0014)
        XCTAssertEqual(try bandwidth(in: estimator), 6_856)
    }

    func testNeutralCandidatesUseNativeExponentialMovingAverage() throws {
        var estimator = AppleVideoRateControlEstimator()
        feedGroup(&estimator, frame: 0, spacing: 0.0003, packetCount: 33)
        feedGroup(&estimator, frame: 1, spacing: 0.0003, packetCount: 33)
        feedGroup(&estimator, frame: 2, spacing: 0.000301, packetCount: 33)
        feedGroup(&estimator, frame: 3, spacing: 0.000301, packetCount: 33)

        XCTAssertEqual(try bandwidth(in: estimator), 31_985)
    }

    func testRelativeThresholdAppliesBelowAbsoluteMargin() throws {
        var estimator = AppleVideoRateControlEstimator()
        feedGroup(&estimator, frame: 0, spacing: 0.8)
        feedGroup(&estimator, frame: 1, spacing: 0.06)
        XCTAssertEqual(try bandwidth(in: estimator), 96)

        feedGroup(&estimator, frame: 2, spacing: 0.06)
        feedGroup(&estimator, frame: 3, spacing: 0.06)
        XCTAssertEqual(try bandwidth(in: estimator), 96)
        feedGroup(&estimator, frame: 4, spacing: 0.06)
        XCTAssertEqual(try bandwidth(in: estimator), 160)
    }

    func testTimestampWrapAdvancesFeedbackState() throws {
        var estimator = AppleVideoRateControlEstimator()
        estimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: UInt32.max - 100,
            arrivalTime: 1,
            packetSize: 1_200
        ))
        estimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: 100,
            arrivalTime: 1.01,
            packetSize: 1_200
        ))

        let feedback = try XCTUnwrap(estimator.feedback(at: 1.02))
        XCTAssertEqual(feedback.rtpTimestamp, 100)
        XCTAssertEqual(feedback.receivedPacketCount, 2)
    }

    func testHighPerformanceTimestampCadenceDoesNotInventQueueingDelay() throws {
        var estimator = AppleVideoRateControlEstimator()
        for frame in 0..<120 {
            estimator.observe(AppleVideoPacketObservation(
                rtpTimestamp: UInt32(24_000 + 400 * frame),
                arrivalTime: 1_000 + Double(frame) / 60,
                packetSize: 1_200
            ))
        }

        let feedback = try XCTUnwrap(estimator.feedback(at: 1_002.05))
        XCTAssertLessThan(feedback.oneWayReceiveDelay, 0.001)
    }

    func testHighPerformanceFeedbackReportsGrowingReceiveDelay() throws {
        var estimator = AppleVideoRateControlEstimator()
        estimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: 24_000,
            arrivalTime: 1_000,
            packetSize: 1_200
        ))
        estimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: 24_400,
            arrivalTime: 1_000 + 1.0 / 60,
            packetSize: 1_200
        ))
        estimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: 24_800,
            arrivalTime: 1_000 + 2.0 / 60 + 0.010,
            packetSize: 1_200
        ))

        let feedback = try XCTUnwrap(estimator.feedback(at: 1_001))
        XCTAssertEqual(feedback.oneWayReceiveDelay, 0.000999, accuracy: 0.000001)
    }

    private func estimate(
        spacing: TimeInterval,
        packetIndexes: [Int] = Array(0..<6),
        insertsOldTimestamp: Bool = false
    ) -> AppleVideoRateControlEstimator {
        var estimator = AppleVideoRateControlEstimator()
        for frame in 0..<120 {
            let timestamp = UInt32(90_000 + 1_500 * frame)
            let frameArrival = 1_000 + Double(frame) / 60
            for packetIndex in packetIndexes {
                if insertsOldTimestamp, frame == 60, packetIndex == 2 {
                    estimator.observe(AppleVideoPacketObservation(
                        rtpTimestamp: timestamp &- 1_500,
                        arrivalTime: frameArrival + Double(packetIndex) * spacing - 0.00001,
                        packetSize: 1_200
                    ))
                }
                estimator.observe(AppleVideoPacketObservation(
                    rtpTimestamp: timestamp,
                    arrivalTime: frameArrival + Double(packetIndex) * spacing,
                    packetSize: 1_200
                ))
            }
        }
        return estimator
    }

    private func feedGroup(
        _ estimator: inout AppleVideoRateControlEstimator,
        frame: Int,
        spacing: TimeInterval,
        packetCount: Int = 6
    ) {
        let timestamp = UInt32(90_000 + 1_500 * frame)
        let frameArrival = 1_000 + Double(frame) / 60
        for packetIndex in 0..<packetCount {
            estimator.observe(AppleVideoPacketObservation(
                rtpTimestamp: timestamp,
                arrivalTime: frameArrival + Double(packetIndex) * spacing,
                packetSize: 1_200
            ))
        }
    }

    private func bandwidth(in estimator: AppleVideoRateControlEstimator) throws -> UInt16 {
        let feedback = try XCTUnwrap(estimator.feedback(at: 1_001))
        return try feedback.serialized().uint16BE(at: 18)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
