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
