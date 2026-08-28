import CoreMedia
import VideoToolbox
import XCTest
@testable import iScreenSharing

final class AppleHEVCDecoderTests: XCTestCase {
    func testPipelinesTileDecodesAsynchronouslyWithoutTemporalReordering() {
        XCTAssertTrue(
            AppleHEVCDecoder.decodeFlags.contains(._EnableAsynchronousDecompression)
        )
        XCTAssertFalse(
            AppleHEVCDecoder.decodeFlags.contains(._EnableTemporalProcessing)
        )
    }

    func testClassifiesDroppedAndMissingVideoToolboxOutputAsCompletedFailures() {
        XCTAssertEqual(
            AppleHEVCDecoder.videoToolboxOutputDisposition(
                status: noErr,
                infoFlags: [.frameDropped],
                hasImageBuffer: false
            ),
            .failure(.frameDropped)
        )
        XCTAssertEqual(
            AppleHEVCDecoder.videoToolboxOutputDisposition(
                status: noErr,
                infoFlags: [],
                hasImageBuffer: false
            ),
            .failure(.missingImageBuffer)
        )
        XCTAssertEqual(
            AppleHEVCDecoder.videoToolboxOutputDisposition(
                status: kVTVideoDecoderBadDataErr,
                infoFlags: [],
                hasImageBuffer: false
            ),
            .failure(.decoderStatus)
        )
        XCTAssertEqual(
            AppleHEVCDecoder.videoToolboxOutputDisposition(
                status: noErr,
                infoFlags: [],
                hasImageBuffer: true
            ),
            .frame
        )
    }

    func testBuildsFourByteLengthPrefixedPayload() throws {
        let unit = Data([0x26, 0x01, 0xaa, 0xbb])
        XCTAssertEqual(
            try AppleHEVCDecoder.lengthPrefixedPayload(for: unit),
            Data([0, 0, 0, 4, 0x26, 0x01, 0xaa, 0xbb])
        )
    }

    func testBuildsOneCompressedSampleFromEveryNALInAnAccessUnit() throws {
        let parameterSet = Data([0x40, 0x01, 0xaa])
        let videoSlice = Data([0x26, 0x01, 0xbb, 0xcc])

        XCTAssertEqual(
            try AppleHEVCDecoder.lengthPrefixedPayload(for: [parameterSet, videoSlice]),
            Data([0, 0, 0, 3, 0x40, 0x01, 0xaa,
                  0, 0, 0, 4, 0x26, 0x01, 0xbb, 0xcc])
        )
    }

    func testRejectsEmptyNALUnitPayload() {
        XCTAssertThrowsError(try AppleHEVCDecoder.lengthPrefixedPayload(for: Data())) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .invalidNALUnit)
        }
    }

    func testRejectsEmptyAccessUnitPayload() {
        XCTAssertThrowsError(try AppleHEVCDecoder.lengthPrefixedPayload(for: [Data]())) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .invalidNALUnit)
        }
    }

    func testRejectsIncompleteParameterSets() {
        XCTAssertThrowsError(
            try AppleHEVCDecoder(parameterSets: AppleHEVCParameterSets()) { _ in }
        ) { error in
            XCTAssertEqual(error as? AppleHEVCDecoderError, .incompleteParameterSets)
        }
    }

    func testRejectsTileIndicesOutsideTheConfiguredDecoderSet() {
        XCTAssertNoThrow(try AppleHEVCDecoder.validateTileIndex(0, tileCount: 4))
        XCTAssertNoThrow(try AppleHEVCDecoder.validateTileIndex(3, tileCount: 4))
        XCTAssertThrowsError(try AppleHEVCDecoder.validateTileIndex(-1, tileCount: 4)) {
            XCTAssertEqual($0 as? AppleHEVCDecoderError, .invalidTileIndex)
        }
        XCTAssertThrowsError(try AppleHEVCDecoder.validateTileIndex(4, tileCount: 4)) {
            XCTAssertEqual($0 as? AppleHEVCDecoderError, .invalidTileIndex)
        }
    }

    func testUsesVideoProcessingOnlyForMultiTileStreamsWhenAvailable() {
        XCTAssertFalse(AppleHEVCDecoder.prefersVideoProcessing(
            tileCount: 1,
            isAvailable: true
        ))
        XCTAssertFalse(AppleHEVCDecoder.prefersVideoProcessing(
            tileCount: 2,
            isAvailable: true
        ))
        XCTAssertFalse(AppleHEVCDecoder.prefersVideoProcessing(
            tileCount: 4,
            isAvailable: false
        ))
        XCTAssertTrue(AppleHEVCDecoder.prefersVideoProcessing(
            tileCount: 4,
            isAvailable: true
        ))
        XCTAssertFalse(AppleHEVCDecoder.prefersVideoProcessing(
            mode: .videoToolboxLowLatency,
            tileCount: 4,
            isAvailable: true
        ))
        XCTAssertFalse(AppleHEVCDecoder.prefersVideoProcessing(
            mode: .videoToolboxSynchronized,
            tileCount: 4,
            isAvailable: true
        ))
        XCTAssertTrue(AppleHEVCDecoder.prefersVideoProcessing(
            mode: .videoProcessing,
            tileCount: 4,
            isAvailable: true
        ))
    }

    func testAllProductModesExceptLowLatencySynchronizeVideoToolboxTiles() {
        XCTAssertTrue(AppleVideoDecoderMode.automatic.synchronizesVideoToolboxTiles)
        XCTAssertTrue(AppleVideoDecoderMode.videoProcessing.synchronizesVideoToolboxTiles)
        XCTAssertTrue(
            AppleVideoDecoderMode.videoToolboxSynchronized.synchronizesVideoToolboxTiles
        )
        XCTAssertFalse(
            AppleVideoDecoderMode.videoToolboxLowLatency.synchronizesVideoToolboxTiles
        )
    }

    func testBuildsNativeSubframeIdentifierFromIndependentTileAndOrderFields() {
        XCTAssertEqual(
            AppleVCPDecompressionSession.subframeIdentifier(tileID: 3, tileOrder: 0x1234),
            Int64(bitPattern: 0x0000_0003_0000_1234)
        )
        XCTAssertNotEqual(
            AppleVCPDecompressionSession.subframeIdentifier(tileID: 3, tileOrder: 0x1234),
            AppleVCPDecompressionSession.subframeIdentifier(tileID: 0x1234, tileOrder: 3)
        )
    }

    func testBuildsNativeVideoProcessingSpecification() {
        let specification = AppleVCPDecompressionSession.decoderSpecification(
            tileCount: 4,
            negotiationDetails: AppleMediaOffer.videoDecoderNegotiationDetails
        ) as NSDictionary

        XCTAssertEqual(
            specification["NegotiationDetails"] as? String,
            AppleMediaOffer.videoDecoderNegotiationDetails
        )
        XCTAssertEqual((specification["NumberOfTiles"] as? NSNumber)?.int64Value, 4)
    }

    func testVideoProcessingTileOrderStartsAtZeroAndWrapsWithinTheSession() {
        var nextOrder: UInt16 = 0
        XCTAssertEqual(AppleHEVCDecoder.takeVideoProcessingTileOrder(from: &nextOrder), 0)
        XCTAssertEqual(AppleHEVCDecoder.takeVideoProcessingTileOrder(from: &nextOrder), 1)

        nextOrder = .max
        XCTAssertEqual(AppleHEVCDecoder.takeVideoProcessingTileOrder(from: &nextOrder), .max)
        XCTAssertEqual(nextOrder, 0)
    }

    func testVideoProcessingReportsAsynchronousDecodeFailure() {
        let metadata = AppleVCPDecompressionSession.FrameMetadata(
            tileIndex: 2,
            tileOrder: 10,
            decodingOrderNumber: 20,
            isLongTermReferenceFrame: true,
            rtpTimestamp: 30,
            presentationTime: 40,
            accessUnitTiming: nil,
            decodeEnteredAt: 38,
            decoderSubmittedAt: 39
        )
        var receivedMetadata: AppleVCPDecompressionSession.FrameMetadata?
        var receivedStatus: OSStatus?
        var successfulDecodeCount = 0

        AppleVCPDecompressionSession.dispatchOutput(
            metadata: metadata,
            status: kVTVideoDecoderReferenceMissingErr,
            imageBuffer: nil,
            frameHandler: { _, _ in XCTFail("Decode failure must not publish a frame") },
            failureHandler: {
                receivedMetadata = $0
                receivedStatus = $1
            },
            successfulDecodeHandler: { _ in successfulDecodeCount += 1 }
        )

        XCTAssertEqual(receivedMetadata?.tileIndex, 2)
        XCTAssertEqual(receivedMetadata?.isLongTermReferenceFrame, true)
        XCTAssertEqual(receivedMetadata?.rtpTimestamp, 30)
        XCTAssertEqual(receivedStatus, kVTVideoDecoderReferenceMissingErr)
        XCTAssertEqual(successfulDecodeCount, 0)
        XCTAssertEqual(
            AppleVCPDecompressionSession.outputDisposition(
                status: kVTVideoDecoderReferenceMissingErr,
                hasImageBuffer: false
            ),
            .failure(kVTVideoDecoderReferenceMissingErr)
        )
    }

    func testVideoProcessingKeepsIncompleteTileAssemblyPending() {
        let metadata = AppleVCPDecompressionSession.FrameMetadata(
            tileIndex: 2,
            tileOrder: 10,
            decodingOrderNumber: 20,
            isLongTermReferenceFrame: true,
            rtpTimestamp: 30,
            presentationTime: 40,
            accessUnitTiming: nil,
            decodeEnteredAt: 38,
            decoderSubmittedAt: 39
        )
        var successfulMetadata: AppleVCPDecompressionSession.FrameMetadata?

        AppleVCPDecompressionSession.dispatchOutput(
            metadata: metadata,
            status: noErr,
            imageBuffer: nil,
            frameHandler: { _, _ in XCTFail("Pending tile must not publish a frame") },
            failureHandler: { _, _ in XCTFail("Pending tile must not report a failure") },
            successfulDecodeHandler: { successfulMetadata = $0 }
        )

        XCTAssertEqual(successfulMetadata?.decodingOrderNumber, 20)
        XCTAssertEqual(
            AppleVCPDecompressionSession.outputDisposition(
                status: noErr,
                hasImageBuffer: false
            ),
            .pending
        )
    }

    func testBuildsNativeCompressedSampleTimingFromPlayoutHostTime() {
        let timing = AppleHEVCDecoder.compressedSampleTiming(presentationTime: 42.5)

        XCTAssertEqual(timing.duration, CMTime(value: 1, timescale: 1))
        XCTAssertEqual(
            timing.presentationTimeStamp,
            CMTime(value: 42_500_000_000, timescale: 1_000_000_000)
        )
        XCTAssertFalse(timing.decodeTimeStamp.isValid)
    }

    func testRequiresDecoderReplacementWhenParameterSetsChange() {
        let configured = AppleHEVCParameterSets(
            video: Data([1]),
            sequence: Data([2]),
            pictures: [Data([3])]
        )
        let changed = AppleHEVCParameterSets(
            video: Data([1]),
            sequence: Data([4]),
            pictures: [Data([3])]
        )

        XCTAssertFalse(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: configured
        ))
        XCTAssertTrue(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: changed
        ))
        XCTAssertFalse(AppleHEVCDecoder.requiresReplacement(
            configured: configured,
            current: AppleHEVCParameterSets()
        ))
    }
}
