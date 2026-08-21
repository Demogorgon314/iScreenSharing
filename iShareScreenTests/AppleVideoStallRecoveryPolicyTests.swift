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
            action(now: 10, frame: 6, packet: 10),
            .requestKeyFrames
        )
    }

    func testRateLimitsKeyFrameRequests() {
        XCTAssertEqual(
            action(now: 10, frame: 6, packet: 10, keyFrameRequest: 9),
            .none
        )
    }

    func testRestartsDecoderAfterProlongedStall() {
        XCTAssertEqual(
            action(now: 10, frame: 1, packet: 10),
            .restartDecoderAndRequestKeyFrames
        )
    }

    func testRateLimitsDecoderRestartsAndFallsBackToKeyFrameRequest() {
        XCTAssertEqual(
            action(now: 10, frame: 1, packet: 10, decoderRestart: 9),
            .requestKeyFrames
        )
    }

    private func action(
        now: TimeInterval,
        frame: TimeInterval,
        packet: TimeInterval,
        keyFrameRequest: TimeInterval = 0,
        decoderRestart: TimeInterval = 0
    ) -> AppleVideoStallRecoveryPolicy.Action {
        policy.action(
            now: now,
            lastDecodedFrameTime: frame,
            lastVideoPacketTime: packet,
            lastKeyFrameRequestTime: keyFrameRequest,
            lastDecoderRestartTime: decoderRestart
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
