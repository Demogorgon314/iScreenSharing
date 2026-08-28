import CoreVideo
import XCTest
@testable import iScreenSharingMobile

final class MobileVideoPresentationTests: XCTestCase {
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
}
