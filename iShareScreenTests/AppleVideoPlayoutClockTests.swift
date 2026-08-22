import XCTest
@testable import iShareScreen

final class AppleVideoPlayoutClockTests: XCTestCase {
    func testAnchorsFirstTimestampToCurrentHostTime() {
        var clock = AppleVideoPlayoutClock()

        XCTAssertEqual(
            clock.presentationTime(for: 90_000, hostTime: 42),
            42
        )
    }

    func testAdvancesPresentationTimeByRTPDeltaInsteadOfArrivalTime() {
        var clock = AppleVideoPlayoutClock()
        _ = clock.presentationTime(for: 90_000, hostTime: 42)

        XCTAssertEqual(
            clock.presentationTime(for: 91_500, hostTime: 99),
            42 + 1.0 / 60.0,
            accuracy: 0.000_001
        )
    }

    func testReturnsIdenticalPresentationTimeForTilesSharingTimestamp() {
        var clock = AppleVideoPlayoutClock()
        let first = clock.presentationTime(for: 180_000, hostTime: 50)

        XCTAssertEqual(
            clock.presentationTime(for: 180_000, hostTime: 75),
            first
        )
    }

    func testHandlesRTPTimestampWraparound() {
        var clock = AppleVideoPlayoutClock()
        _ = clock.presentationTime(for: UInt32.max - 749, hostTime: 10)

        XCTAssertEqual(
            clock.presentationTime(for: 750, hostTime: 20),
            10 + 1.0 / 60.0,
            accuracy: 0.000_001
        )
    }

    func testPreventsSmallBackwardPresentationTimeJump() {
        var clock = AppleVideoPlayoutClock()
        _ = clock.presentationTime(for: 90_000, hostTime: 10)

        XCTAssertEqual(
            clock.presentationTime(for: 89_100, hostTime: 11),
            10
        )
    }

    func testReanchorsAfterTimestampDiscontinuity() {
        var clock = AppleVideoPlayoutClock()
        _ = clock.presentationTime(for: 90_000, hostTime: 10)

        XCTAssertEqual(
            clock.presentationTime(for: 360_000, hostTime: 20),
            20
        )
    }

    func testResetUsesNewHostAnchor() {
        var clock = AppleVideoPlayoutClock()
        _ = clock.presentationTime(for: 90_000, hostTime: 10)

        clock.reset()

        XCTAssertEqual(
            clock.presentationTime(for: 180_000, hostTime: 30),
            30
        )
    }
}
