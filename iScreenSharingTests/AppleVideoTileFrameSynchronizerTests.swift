import CoreVideo
import XCTest
@testable import iScreenSharing

final class AppleVideoTileFrameSynchronizerTests: XCTestCase {
    func testDrainsSparseTilesInSubmissionOrderAfterEveryTileCompletes() throws {
        let synchronizer = AppleVideoTileFrameSynchronizer()
        synchronizer.recordSubmission(frameSequenceNumber: 100, tileIndex: 0)
        synchronizer.recordSubmission(frameSequenceNumber: 100, tileIndex: 3)

        XCTAssertFalse(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 3, frameSequenceNumber: 100)
        ))
        XCTAssertTrue(synchronizer.drainReadyBatches().isEmpty)
        XCTAssertFalse(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 0, frameSequenceNumber: 100)
        ))
        XCTAssertTrue(synchronizer.recordSubmission(frameSequenceNumber: 101, tileIndex: 1))

        let batches = synchronizer.drainReadyBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.region), [.tile(0), .tile(3)])
    }

    func testPreservesSenderOrderAcrossFrameSequenceWraparound() throws {
        let synchronizer = AppleVideoTileFrameSynchronizer()
        synchronizer.recordSubmission(frameSequenceNumber: .max, tileIndex: 2)
        synchronizer.recordSubmission(frameSequenceNumber: 0, tileIndex: 1)

        XCTAssertFalse(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 1, frameSequenceNumber: 0)
        ))
        XCTAssertTrue(synchronizer.drainReadyBatches().isEmpty)
        XCTAssertTrue(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 2, frameSequenceNumber: .max)
        ))

        XCTAssertEqual(
            synchronizer.drainReadyBatches().map { $0.map(\.region) },
            [[.tile(2)]]
        )
        XCTAssertTrue(synchronizer.recordSubmission(frameSequenceNumber: 1, tileIndex: 0))
        XCTAssertEqual(
            synchronizer.drainReadyBatches().map { $0.map(\.region) },
            [[.tile(1)]]
        )
    }

    func testDecodeFailureReleasesRemainingTilesWithoutPublishingFailedTile() throws {
        let synchronizer = AppleVideoTileFrameSynchronizer()
        synchronizer.recordSubmission(frameSequenceNumber: 42, tileIndex: 0)
        synchronizer.recordSubmission(frameSequenceNumber: 42, tileIndex: 1)
        XCTAssertFalse(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 0, frameSequenceNumber: 42)
        ))
        XCTAssertFalse(synchronizer.recordDecodeFailure(
            frameSequenceNumber: 42,
            tileIndex: 1
        ))
        XCTAssertTrue(synchronizer.recordSubmission(frameSequenceNumber: 43, tileIndex: 0))

        let batches = synchronizer.drainReadyBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.region), [.tile(0)])
    }

    func testResetDiscardsPendingLogicalFrames() throws {
        let synchronizer = AppleVideoTileFrameSynchronizer()
        synchronizer.recordSubmission(frameSequenceNumber: 7, tileIndex: 0)
        synchronizer.reset()

        XCTAssertFalse(synchronizer.recordDecodedFrame(
            try makeFrame(tileIndex: 0, frameSequenceNumber: 7)
        ))
        XCTAssertTrue(synchronizer.drainReadyBatches().isEmpty)
    }

    private func makeFrame(
        tileIndex: Int,
        frameSequenceNumber: UInt16
    ) throws -> AppleHEVCDecoder.DecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            1,
            1,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ), kCVReturnSuccess)
        return AppleHEVCDecoder.DecodedFrame(
            region: .tile(tileIndex),
            decodingOrderNumber: nil,
            rtpTimestamp: 0,
            presentationTime: 0,
            decodeDuration: 0,
            accessUnitTiming: AppleHEVCAccessUnit.Timing(
                traceSequence: UInt64(frameSequenceNumber),
                observedFrameSequenceNumber: frameSequenceNumber,
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
