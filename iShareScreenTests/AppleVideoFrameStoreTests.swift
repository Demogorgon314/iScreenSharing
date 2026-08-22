import CoreVideo
import XCTest
@testable import iShareScreen

final class AppleVideoFrameStoreTests: XCTestCase {
    func testStreamAllowsOneSourceFrameForLateTiles() {
        XCTAssertGreaterThanOrEqual(
            AppleVideoStream.maximumPresentationWait,
            1.0 / 60.0
        )
    }

    func testPublishesStoresAndRemovesFrameObservers() async throws {
        let store = AppleVideoFrameStore()
        let firstFrame = try makePixelBuffer(width: 8, height: 8)
        let secondFrame = try makePixelBuffer(width: 16, height: 8)
        let published = expectation(description: "Frame published")
        let identifier = store.addObserver { _ in
            published.fulfill()
        }

        store.publish(firstFrame, at: 2)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(store.frame(at: 2) === firstFrame)

        store.removeObserver(identifier)
        store.publish(secondFrame, at: 2)
        await Task.yield()
        XCTAssertTrue(store.frame(at: 2) === secondFrame)

        store.removeAllFrames()
        XCTAssertNil(store.frame(at: 2))
    }

    @MainActor
    func testCoalescesBurstUpdatesIntoLatestFrameBatch() async throws {
        let store = AppleVideoFrameStore()
        let firstFrame = try makePixelBuffer(width: 8, height: 8)
        let latestFrame = try makePixelBuffer(width: 16, height: 8)
        let secondTileFrame = try makePixelBuffer(width: 16, height: 16)
        let published = expectation(description: "Latest frame published")
        var receivedBatches = [AppleVideoFrameStore.FrameBatch]()
        _ = store.addObserver { frames in
            receivedBatches.append(frames)
            published.fulfill()
        }

        store.publish(firstFrame, at: 0)
        store.publish(latestFrame, at: 0)
        store.publish(secondTileFrame, at: 1)

        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(receivedBatches.count, 1)
        XCTAssertTrue(receivedBatches.first?[0]?.pixelBuffer === latestFrame)
        XCTAssertTrue(receivedBatches.first?[1]?.pixelBuffer === secondTileFrame)
    }

    @MainActor
    func testDeliversCompleteTileSnapshotWhenOneTileChanges() async throws {
        let store = AppleVideoFrameStore()
        let firstTile = try makePixelBuffer(width: 8, height: 8)
        let secondTile = try makePixelBuffer(width: 8, height: 8)
        let updatedSecondTile = try makePixelBuffer(width: 16, height: 8)
        store.publish(firstTile, at: 0)
        store.publish(secondTile, at: 1)
        await Task.yield()

        let published = expectation(description: "Complete frame snapshot")
        var received: AppleVideoFrameStore.FrameBatch?
        _ = store.addObserver { frames in
            received = frames
            published.fulfill()
        }
        store.publish(updatedSecondTile, at: 1)

        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(received?[0]?.pixelBuffer === firstTile)
        XCTAssertTrue(received?[1]?.pixelBuffer === updatedSecondTile)
    }

    @MainActor
    func testDeliversChangedTileWithoutWaitingForUnchangedTiles() async throws {
        let store = AppleVideoFrameStore()
        let published = expectation(description: "Incremental tile update")
        var received: AppleVideoFrameStore.FrameBatch?
        _ = store.addObserver { frames in
            received = frames
            published.fulfill()
        }

        let changedTile = try makePixelBuffer(width: 8, height: 8)
        store.publish(
            changedTile,
            at: 2,
            decodingOrderNumber: 100
        )
        await fulfillment(of: [published], timeout: 1)

        XCTAssertTrue(received?[2]?.pixelBuffer === changedTile)
    }

    @MainActor
    func testCoalescesTilesWithSharedRTPTimestampIntoOnePresentation() async throws {
        let store = AppleVideoFrameStore(expectedTileCount: 4, presentationDelay: 1)
        let published = expectation(description: "Shared RTP timestamp presented")
        var receivedBatches = [AppleVideoFrameStore.FrameBatch]()
        _ = store.addObserver { frames in
            receivedBatches.append(frames)
            published.fulfill()
        }

        let firstTimestampFrames = try (0..<4).map { tileIndex in
            let frame = try makePixelBuffer(width: 8, height: 8)
            store.publish(
                frame,
                at: tileIndex,
                decodingOrderNumber: UInt16(100 + tileIndex),
                rtpTimestamp: 90_000
            )
            return frame
        }
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(receivedBatches.count, 1)
        for tileIndex in 0..<4 {
            XCTAssertTrue(receivedBatches[0][tileIndex]?.pixelBuffer === firstTimestampFrames[tileIndex])
            XCTAssertEqual(receivedBatches[0][tileIndex]?.rtpTimestamp, 90_000)
        }
    }

    @MainActor
    func testPresentsSingleChangedTileAfterPlayoutDeadline() async throws {
        let store = AppleVideoFrameStore(presentationDelay: 0.01)
        let published = expectation(description: "Incremental tile deadline")
        var received: AppleVideoFrameStore.FrameBatch?
        _ = store.addObserver { frames in
            received = frames
            published.fulfill()
        }

        let changedTile = try makePixelBuffer(width: 8, height: 8)
        store.publish(
            changedTile,
            at: 2,
            decodingOrderNumber: 200,
            rtpTimestamp: 180_000
        )

        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(received?[2]?.pixelBuffer === changedTile)
        XCTAssertEqual(received?[2]?.rtpTimestamp, 180_000)
    }

    @MainActor
    func testPresentsSealedPartialTimestampAsSoonAsExpectedTilesDecode() async throws {
        let store = AppleVideoFrameStore(expectedTileCount: 4, presentationDelay: 1)
        let published = expectation(description: "Sealed timestamp presented")
        var received: AppleVideoFrameStore.FrameBatch?
        _ = store.addObserver { frames in
            received = frames
            published.fulfill()
        }
        store.seal(rtpTimestamp: 270_000, expectedTileIndices: [0, 1, 2])

        for tileIndex in 0..<3 {
            store.publish(
                try makePixelBuffer(width: 8, height: 8),
                at: tileIndex,
                decodingOrderNumber: UInt16(300 + tileIndex),
                rtpTimestamp: 270_000
            )
        }

        await fulfillment(of: [published], timeout: 0.2)
        XCTAssertEqual(Set(received?.keys.map { $0 } ?? []), Set([0, 1, 2]))
    }

    @MainActor
    func testPresentsPartialTimestampWhenSealedAfterDecode() async throws {
        let store = AppleVideoFrameStore(expectedTileCount: 4, presentationDelay: 1)
        let published = expectation(description: "Decoded timestamp sealed")
        var received: AppleVideoFrameStore.FrameBatch?
        _ = store.addObserver { frames in
            received = frames
            published.fulfill()
        }
        for tileIndex in 0..<2 {
            store.publish(
                try makePixelBuffer(width: 8, height: 8),
                at: tileIndex,
                decodingOrderNumber: UInt16(400 + tileIndex),
                rtpTimestamp: 360_000
            )
        }

        store.seal(rtpTimestamp: 360_000, expectedTileIndices: [0, 1])

        await fulfillment(of: [published], timeout: 0.2)
        XCTAssertEqual(Set(received?.keys.map { $0 } ?? []), Set([0, 1]))
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }
}
