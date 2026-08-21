import CoreVideo
import XCTest
@testable import iShareScreen

final class AppleVideoFrameStoreTests: XCTestCase {
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
        XCTAssertTrue(receivedBatches.first?[0] === latestFrame)
        XCTAssertTrue(receivedBatches.first?[1] === secondTileFrame)
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
        XCTAssertTrue(received?[0] === firstTile)
        XCTAssertTrue(received?[1] === updatedSecondTile)
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
