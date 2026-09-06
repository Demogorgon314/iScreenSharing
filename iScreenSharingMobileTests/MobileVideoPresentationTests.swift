import CoreVideo
import XCTest
@testable import iScreenSharingMobile

final class MobileVideoPresentationTests: XCTestCase {
    @MainActor
    func testMobileMetalHUDCanBeEnabledAndDisabledWithoutReplacingLayer() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)
        XCTAssertEqual(layer.developerHUDProperties?["mode"] as? String, "disabled")
        layer.showsDeveloperHUD = true
        XCTAssertEqual(layer.developerHUDProperties?["mode"] as? String, "default")
        layer.showsDeveloperHUD = false
        XCTAssertEqual(layer.developerHUDProperties?["mode"] as? String, "disabled")
    }

    @MainActor
    func testMobileFrameStorePreservesConsecutiveLogicalFrames() async throws {
        let store = AppleVideoFrameStore(preservesLogicalFrameBatches: true)
        let first = try makeDecodedFrame(sequence: 1)
        let second = try makeDecodedFrame(sequence: 2)
        let delivered = expectation(description: "Logical frames delivered")
        delivered.expectedFulfillmentCount = 2
        var sequences = [UInt16]()
        _ = store.addObserver { frames in
            if let sequence = frames[0]?.accessUnitTiming?.observedFrameSequenceNumber {
                sequences.append(sequence)
            }
            delivered.fulfill()
        }

        store.publish([first], playbackHandledAt: 1)
        store.publish([second], playbackHandledAt: 2)

        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(sequences, [1, 2])
    }

    @MainActor
    func testMobileFrameStoreDropsOldestLogicalFrameAtCapacity() async throws {
        let store = AppleVideoFrameStore(
            preservesLogicalFrameBatches: true,
            logicalFrameQueueCapacity: 2
        )
        let delivered = expectation(description: "Newest logical frames delivered")
        delivered.expectedFulfillmentCount = 2
        var sequences = [UInt16]()
        _ = store.addObserver { frames in
            if let sequence = frames[0]?.accessUnitTiming?.observedFrameSequenceNumber {
                sequences.append(sequence)
            }
            delivered.fulfill()
        }

        store.publish([try makeDecodedFrame(sequence: 1)], playbackHandledAt: 1)
        store.publish([try makeDecodedFrame(sequence: 2)], playbackHandledAt: 2)
        store.publish([try makeDecodedFrame(sequence: 3)], playbackHandledAt: 3)

        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(sequences, [2, 3])
    }

    func testOnDemandFrameStoreLetsDisplayDriverPullLogicalFrames() throws {
        let store = AppleVideoFrameStore(
            preservesLogicalFrameBatches: true,
            logicalFrameQueueCapacity: 2,
            deliversLogicalFrameBatchesOnDemand: true
        )
        store.publish([try makeDecodedFrame(sequence: 1)], playbackHandledAt: 1)
        store.publish([try makeDecodedFrame(sequence: 2)], playbackHandledAt: 2)

        let first = store.dequeueLogicalFrameBatch()
        let second = store.dequeueLogicalFrameBatch()

        XCTAssertEqual(first?[0]?.accessUnitTiming?.observedFrameSequenceNumber, 1)
        XCTAssertEqual(second?[0]?.accessUnitTiming?.observedFrameSequenceNumber, 2)
        XCTAssertNil(store.dequeueLogicalFrameBatch())
    }

    func testRendererGateAllowsDoubleBufferedSubmission() {
        let gate = AppleMetalInFlightGate(maximumInFlightCount: 2)

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())

        gate.end()
        XCTAssertTrue(gate.begin())
        gate.end()
        gate.end()
    }

    func testDisplayLinkOnlySchedulerKeepsEnqueuedFrameUntilNextTick() throws {
        var scheduler = AppleVideoDisplayScheduler(presentsOnEnqueue: false)
        _ = scheduler.displayLinkDidFire(targetTimestamp: 10)

        let enqueueUpdate = scheduler.enqueue([
            0: try makeFrame(sequence: 1, presentationTime: 10),
        ])
        let nextTick = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertNil(enqueueUpdate)
        XCTAssertEqual(nextTick.frames[0]?.sequence, 1)
        XCTAssertTrue(nextTick.requiresPresentation)
        XCTAssertEqual(nextTick.trigger, .displayLinkTick)
    }

    func testBatchPreservingSchedulerPresentsOneLogicalBatchPerTick() throws {
        var scheduler = AppleVideoDisplayScheduler(
            presentsOnEnqueue: false,
            preservesEnqueuedBatches: true
        )
        _ = scheduler.displayLinkDidFire(targetTimestamp: 10)
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 9)])
        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 9.5)])

        let firstTick = scheduler.displayLinkDidFire(targetTimestamp: 11)
        let secondTick = scheduler.displayLinkDidFire(targetTimestamp: 12)

        XCTAssertEqual(firstTick.frames[0]?.sequence, 1)
        XCTAssertEqual(secondTick.frames[0]?.sequence, 2)
    }

    func testBatchPreservingSchedulerDropsOldestBatchAtCapacity() throws {
        var scheduler = AppleVideoDisplayScheduler(
            queueCapacity: 2,
            presentsOnEnqueue: false,
            preservesEnqueuedBatches: true
        )
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 9)])
        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 10)])
        scheduler.enqueue([0: try makeFrame(sequence: 3, presentationTime: 11)])

        let firstTick = scheduler.displayLinkDidFire(targetTimestamp: 12)
        let secondTick = scheduler.displayLinkDidFire(targetTimestamp: 13)

        XCTAssertEqual(firstTick.frames[0]?.sequence, 2)
        XCTAssertEqual(secondTick.frames[0]?.sequence, 3)
    }

    func testLowLatencySchedulerPresentsFutureFrameWhenBacklogged() throws {
        var scheduler = AppleVideoDisplayScheduler(
            queueCapacity: 2,
            presentsOnEnqueue: false,
            preservesEnqueuedBatches: true,
            presentsEarlyWhenBacklogged: true
        )
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 20)])

        let waitingTick = scheduler.displayLinkDidFire(targetTimestamp: 10)

        scheduler.enqueue([0: try makeFrame(sequence: 2, presentationTime: 21)])
        let catchUpTick = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertTrue(waitingTick.frames.isEmpty)
        XCTAssertEqual(catchUpTick.frames[0]?.sequence, 1)
    }

    func testBusyRendererRetriesPresentationOnNextDisplayTick() throws {
        var scheduler = AppleVideoDisplayScheduler()
        scheduler.enqueue([0: try makeFrame(sequence: 1, presentationTime: 10)])

        let firstTick = scheduler.displayLinkDidFire(targetTimestamp: 10)
        XCTAssertTrue(firstTick.requiresPresentation)
        XCTAssertEqual(firstTick.frames[0]?.sequence, 1)

        scheduler.presentationDidFail()
        let retryTick = scheduler.displayLinkDidFire(targetTimestamp: 11)

        XCTAssertTrue(retryTick.requiresPresentation)
        XCTAssertTrue(retryTick.frames.isEmpty)
        XCTAssertEqual(retryTick.trigger, .displayLinkTick)
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

    private func makeDecodedFrame(sequence: UInt16) throws -> AppleHEVCDecoder.DecodedFrame {
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
        return AppleHEVCDecoder.DecodedFrame(
            region: .tile(0),
            decodingOrderNumber: sequence,
            rtpTimestamp: UInt32(sequence),
            presentationTime: Double(sequence),
            decodeDuration: 0,
            accessUnitTiming: AppleHEVCAccessUnit.Timing(
                traceSequence: UInt64(sequence),
                observedFrameSequenceNumber: sequence,
                firstDatagramObservedAt: 0,
                completingDatagramObservedAt: 0,
                assemblyCompletedAt: 0
            ),
            decodeEnteredAt: 0,
            decoderSubmittedAt: 0,
            decoderOutputAt: 0,
            pixelBuffer: try XCTUnwrap(pixelBuffer)
        )
    }
}
