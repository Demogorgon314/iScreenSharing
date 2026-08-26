import CoreVideo
import XCTest
@testable import iScreenSharing

final class AppleVideoDisplaySchedulerTests: XCTestCase {
    func testKeepsFutureFrameUntilItsFirstEligibleDisplayTick() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])

        let earlyUpdate = scheduler.displayLinkDidFire(targetTimestamp: 9)

        XCTAssertTrue(earlyUpdate.frames.isEmpty)
        XCTAssertFalse(earlyUpdate.requiresPresentation)
        XCTAssertEqual(scheduler.queuedFrameCount, 1)

        let eligibleUpdate = scheduler.displayLinkDidFire(targetTimestamp: 10)

        XCTAssertEqual(eligibleUpdate.frames[0]?.sequence, 1)
        XCTAssertTrue(eligibleUpdate.requiresPresentation)
        XCTAssertEqual(scheduler.queuedFrameCount, 0)
    }

    func testEligibleFrameProcessesImmediatelyAfterDisplayTargetIsKnown() throws {
        var scheduler = AppleVideoDisplayScheduler()
        let emptyTick = scheduler.displayLinkDidFire(targetTimestamp: 10, period: 0.008)

        let update = try XCTUnwrap(scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 9),
        ]))

        XCTAssertTrue(emptyTick.frames.isEmpty)
        XCTAssertFalse(emptyTick.requiresPresentation)
        XCTAssertEqual(update.frames[0]?.sequence, 1)
        XCTAssertTrue(update.requiresPresentation)
        XCTAssertEqual(update.targetTimestamp, 10)
        XCTAssertEqual(update.displayPeriod, 0.008)
        XCTAssertEqual(update.trigger, .enqueueUsingPreviousTarget)
        XCTAssertEqual(emptyTick.trigger, .displayLinkTick)
        XCTAssertEqual(scheduler.queuedFrameCount, 0)
    }

    func testFutureFrameStillWaitsWhenEnqueuedAfterDisplayTargetIsKnown() throws {
        var scheduler = AppleVideoDisplayScheduler()
        _ = scheduler.displayLinkDidFire(targetTimestamp: 10)

        let immediateUpdate = try XCTUnwrap(scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 11),
        ]))
        let eligibleUpdate = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertTrue(immediateUpdate.frames.isEmpty)
        XCTAssertFalse(immediateUpdate.requiresPresentation)
        XCTAssertEqual(eligibleUpdate.frames[0]?.sequence, 1)
    }

    func testInvalidatedDisplayTargetDoesNotReleaseFrameUntilNextTick() throws {
        var scheduler = AppleVideoDisplayScheduler()
        _ = scheduler.displayLinkDidFire(targetTimestamp: 10)
        scheduler.invalidateDisplayTarget()

        let immediateUpdate = scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 9),
        ])
        let nextTick = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertNil(immediateUpdate)
        XCTAssertEqual(nextTick.frames[0]?.sequence, 1)
    }

    func testSixtyFPSFrameUsesFirstEligibleTickOn144HzDisplay() throws {
        var scheduler = AppleVideoDisplayScheduler()
        let displayPeriod = 1.0 / 144.0
        scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 1.0 / 60.0),
        ])
        var presentedTargets = [TimeInterval]()

        for tick in 1...3 {
            let targetTimestamp = Double(tick) * displayPeriod
            let update = scheduler.displayLinkDidFire(
                targetTimestamp: targetTimestamp
            )
            if update.requiresPresentation { presentedTargets.append(targetTimestamp) }
        }

        XCTAssertEqual(presentedTargets.count, 1)
        XCTAssertEqual(presentedTargets[0], 3 * displayPeriod, accuracy: 0.000_001)
    }

    func testDisplaysTilesWithSamePresentationTimeInOneBatch() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 20),
            1: try makeFrame(sequence: 2, presentationTime: 20),
            2: try makeFrame(sequence: 3, presentationTime: 20),
            3: try makeFrame(sequence: 4, presentationTime: 20),
        ])
        let update = scheduler.displayLinkDidFire(targetTimestamp: 20)

        XCTAssertEqual(Set(update.frames.keys), Set(0..<4))
    }

    func testLateFramesCollapseToLatestFramePerTileInSameTick() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])
        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 11)])
        scheduler.enqueue([0: try makeFrame(sequence: 3, presentationTime: 12)])
        let update = scheduler.displayLinkDidFire(targetTimestamp: 20)

        XCTAssertEqual(update.frames[0]?.sequence, 3)
        XCTAssertEqual(scheduler.queuedFrameCount, 0)
    }

    func testFullTileQueueDropsNewestFrameAndKeepsExistingFrames() throws {
        var scheduler = AppleVideoDisplayScheduler(queueCapacity: 2)
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])
        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 11)])
        scheduler.enqueue([0: try makeFrame(sequence: 3, presentationTime: 12)])
        let update = scheduler.displayLinkDidFire(targetTimestamp: 20)

        XCTAssertEqual(update.frames[0]?.sequence, 2)
    }

    func testRepeatedFrameSnapshotIsNotQueuedTwice() throws {
        var scheduler = AppleVideoDisplayScheduler()
        let frame = try makeFrame(sequence: 1, presentationTime: 10)

        scheduler.enqueue([0: frame])
        scheduler.enqueue([0: frame])

        XCTAssertEqual(scheduler.queuedFrameCount, 1)
    }

    func testDropsLateAsyncDecodeCallbackAfterNewerFrameWasDisplayed() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 11)])
        let newerUpdate = scheduler.displayLinkDidFire(targetTimestamp: 11)

        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 10)])
        let staleUpdate = scheduler.displayLinkDidFire(targetTimestamp: 12)

        XCTAssertEqual(newerUpdate.frames[0]?.presentationTime, 11)
        XCTAssertTrue(staleUpdate.frames.isEmpty)
        XCTAssertFalse(staleUpdate.requiresPresentation)
    }

    func testFailedPresentationRetriesWithoutRedisplayingDequeuedFrames() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])
        let failedUpdate = scheduler.displayLinkDidFire(targetTimestamp: 10)
        scheduler.presentationDidFail()
        let retryUpdate = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertEqual(failedUpdate.frames[0]?.sequence, 1)
        XCTAssertTrue(failedUpdate.requiresPresentation)
        XCTAssertTrue(retryUpdate.frames.isEmpty)
        XCTAssertTrue(retryUpdate.requiresPresentation)
    }

    func testDisplaySideEffectCanScheduleAnotherPresentation() throws {
        let owner = PresentationOwner()
        owner.scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])

        owner.displayLinkDidFire(targetTimestamp: 10)
        owner.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertEqual(owner.presentationCount, 2)
    }

    private func makeFrame(
        sequence: UInt64,
        presentationTime: TimeInterval
    ) throws -> AppleVideoFrameStore.Frame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                8,
                8,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return AppleVideoFrameStore.Frame(
            pixelBuffer: try XCTUnwrap(pixelBuffer),
            decodingOrderNumber: UInt16(truncatingIfNeeded: sequence),
            rtpTimestamp: UInt32(truncatingIfNeeded: sequence),
            accessUnitTiming: nil,
            decodeEnteredAt: presentationTime,
            decoderSubmittedAt: presentationTime,
            decoderOutputAt: presentationTime,
            playbackHandledAt: presentationTime,
            decodedAt: presentationTime,
            presentationTime: presentationTime,
            sequence: sequence
        )
    }
}

private final class PresentationOwner {
    var scheduler = AppleVideoDisplayScheduler()
    private(set) var presentationCount = 0

    func displayLinkDidFire(targetTimestamp: TimeInterval) {
        let update = scheduler.displayLinkDidFire(targetTimestamp: targetTimestamp)
        if !update.frames.isEmpty { layoutDidChange() }
        if update.requiresPresentation {
            presentationCount += 1
        }
    }

    private func layoutDidChange() {
        scheduler.markNeedsPresentation()
    }
}
