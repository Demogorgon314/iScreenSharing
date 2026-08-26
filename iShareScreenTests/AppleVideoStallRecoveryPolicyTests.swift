import XCTest
@testable import iShareScreen

final class AppleVideoStallRecoveryPolicyTests: XCTestCase {
    private let policy = AppleVideoStallRecoveryPolicy()

    func testDoesNothingWhileFramesAreCurrent() {
        XCTAssertEqual(
            action(now: 10, frame: 9, packet: 10),
            .none
        )
    }

    func testDoesNothingWhenRemoteEncoderIsIdle() {
        XCTAssertEqual(
            action(now: 10, frame: 1, packet: 8),
            .none
        )
    }

    func testRequestsKeyFramesWhilePacketsFlowButFramesAreStalled() {
        XCTAssertEqual(
            action(now: 10, frame: 4, packet: 10),
            .requestKeyFrames
        )
    }

    func testRateLimitsKeyFrameRequests() {
        XCTAssertEqual(
            action(now: 10, frame: 4, packet: 10, keyFrameRequest: 9),
            .none
        )
    }

    func testProlongedStallStillUsesProtocolRefreshInsteadOfReplacingDecoder() {
        XCTAssertEqual(
            action(now: 10, frame: 1, packet: 10),
            .requestKeyFrames
        )
    }

    private func action(
        now: TimeInterval,
        frame: TimeInterval,
        packet: TimeInterval,
        keyFrameRequest: TimeInterval = 0
    ) -> AppleVideoStallRecoveryPolicy.Action {
        policy.action(
            now: now,
            lastDisplayedFrameTime: frame,
            lastVideoPacketTime: packet,
            lastKeyFrameRequestTime: keyFrameRequest
        )
    }
}

final class AppleVideoRefreshSchedulerTests: XCTestCase {
    func testAcceptsRefreshImmediately() {
        var scheduler = AppleVideoRefreshScheduler()

        XCTAssertTrue(scheduler.accept(timestamp: 100))
    }

    func testDeduplicatesTimestampWithoutSuppressingAChangedRequest() {
        var scheduler = AppleVideoRefreshScheduler()

        XCTAssertTrue(scheduler.accept(timestamp: 100))
        XCTAssertFalse(scheduler.accept(timestamp: 100))
        XCTAssertTrue(scheduler.accept(timestamp: 101))
    }

    func testWatchdogRequestsWithoutTimestampCanRepeat() {
        var scheduler = AppleVideoRefreshScheduler()

        XCTAssertTrue(scheduler.accept(timestamp: nil))
        XCTAssertTrue(scheduler.accept(timestamp: nil))
    }

    func testResetClearsTimestampDeduplication() {
        var scheduler = AppleVideoRefreshScheduler()
        XCTAssertTrue(scheduler.accept(timestamp: 100))

        scheduler.reset()
        XCTAssertTrue(scheduler.accept(timestamp: 100))
    }
}

final class AppleVideoWarmRestartSourcePolicyTests: XCTestCase {
    private let previousSourceToTile: [UInt32: Int] = [
        103: 3,
        101: 1,
        100: 0,
        102: 2,
    ]

    func testReusesPreviousTileOrderAfterEverySourceProducesACompleteAccessUnit() {
        XCTAssertEqual(
            AppleVideoWarmRestartSourcePolicy.sources(
                previousSourceToTile: previousSourceToTile,
                observedSources: [100, 101, 102, 103],
                tileCount: 4
            ),
            [100, 101, 102, 103]
        )
    }

    func testWaitsWhenAnyPreviousSourceHasNotProducedACompleteAccessUnit() {
        XCTAssertNil(
            AppleVideoWarmRestartSourcePolicy.sources(
                previousSourceToTile: previousSourceToTile,
                observedSources: [100, 101, 103],
                tileCount: 4
            )
        )
    }

    func testRejectsPreviousMappingWhenTileCountChanges() {
        XCTAssertNil(
            AppleVideoWarmRestartSourcePolicy.sources(
                previousSourceToTile: previousSourceToTile,
                observedSources: [100, 101, 102, 103],
                tileCount: 2
            )
        )
    }

    func testRejectsMalformedPreviousMapping() {
        XCTAssertNil(
            AppleVideoWarmRestartSourcePolicy.sources(
                previousSourceToTile: [100: 0, 101: 0],
                observedSources: [100, 101],
                tileCount: 2
            )
        )
    }
}

final class AppleVideoFreshRestartSourcePolicyTests: XCTestCase {
    func testSelectsCompleteFreshGroupWhenParameterSetsAreReady() {
        XCTAssertEqual(
            AppleVideoFreshRestartSourcePolicy.sources(
                currentSources: [200, 201, 202, 203],
                completedAccessUnitSources: [200, 201, 202, 203],
                tileCount: 4,
                hasCompleteParameterSets: true
            ),
            [200, 201, 202, 203]
        )
    }

    func testWaitsForEveryFreshSourceToProduceACompleteAccessUnit() {
        XCTAssertNil(
            AppleVideoFreshRestartSourcePolicy.sources(
                currentSources: [200, 201, 202, 203],
                completedAccessUnitSources: [200, 201, 203],
                tileCount: 4,
                hasCompleteParameterSets: true
            )
        )
    }

    func testWaitsForCompleteParameterSets() {
        XCTAssertNil(
            AppleVideoFreshRestartSourcePolicy.sources(
                currentSources: [200, 201, 202, 203],
                completedAccessUnitSources: [200, 201, 202, 203],
                tileCount: 4,
                hasCompleteParameterSets: false
            )
        )
    }

    func testRejectsDuplicateOrIncompleteSourceGroup() {
        XCTAssertNil(
            AppleVideoFreshRestartSourcePolicy.sources(
                currentSources: [200, 201, 201, 203],
                completedAccessUnitSources: [200, 201, 203],
                tileCount: 4,
                hasCompleteParameterSets: true
            )
        )
        XCTAssertNil(
            AppleVideoFreshRestartSourcePolicy.sources(
                currentSources: [200, 201, 202],
                completedAccessUnitSources: [200, 201, 202],
                tileCount: 4,
                hasCompleteParameterSets: true
            )
        )
    }
}

final class AppleVideoInitialRecoveryPolicyTests: XCTestCase {
    private let policy = AppleVideoInitialRecoveryPolicy()

    func testRequestsKeyFramesWhenPacketsFlowButParameterSetsAreMissing() {
        XCTAssertTrue(
            policy.shouldRequestKeyFrames(
                now: 4,
                initialBurstReadyTime: 1,
                lastVideoPacketTime: 4,
                lastKeyFrameRequestTime: 0,
                hasSelectedSources: true,
                hasCompleteParameterSets: false
            )
        )
    }

    func testDoesNothingBeforeSourcesAreSelected() {
        XCTAssertFalse(
            shouldRequest(hasSelectedSources: false)
        )
    }

    func testDoesNothingWhenParameterSetsAreComplete() {
        XCTAssertFalse(
            shouldRequest(hasCompleteParameterSets: true)
        )
    }

    func testDoesNothingWhenVideoPacketsStopped() {
        XCTAssertFalse(
            shouldRequest(now: 4, lastVideoPacketTime: 2)
        )
    }

    func testWaitsForInitialParameterSetGracePeriod() {
        XCTAssertFalse(
            shouldRequest(now: 2, initialBurstReadyTime: 1)
        )
    }

    func testRateLimitsKeyFrameRequests() {
        XCTAssertFalse(
            shouldRequest(now: 4, lastKeyFrameRequestTime: 3)
        )
    }

    private func shouldRequest(
        now: TimeInterval = 4,
        initialBurstReadyTime: TimeInterval = 1,
        lastVideoPacketTime: TimeInterval = 4,
        lastKeyFrameRequestTime: TimeInterval = 0,
        hasSelectedSources: Bool = true,
        hasCompleteParameterSets: Bool = false
    ) -> Bool {
        policy.shouldRequestKeyFrames(
            now: now,
            initialBurstReadyTime: initialBurstReadyTime,
            lastVideoPacketTime: lastVideoPacketTime,
            lastKeyFrameRequestTime: lastKeyFrameRequestTime,
            hasSelectedSources: hasSelectedSources,
            hasCompleteParameterSets: hasCompleteParameterSets
        )
    }
}
