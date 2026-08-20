import CoreVideo
import XCTest
@testable import iShareScreen

final class AppleVideoFrameStoreTests: XCTestCase {
    func testPublishesStoresAndRemovesFrameObservers() async throws {
        let store = AppleVideoFrameStore()
        let firstFrame = try makePixelBuffer(width: 8, height: 8)
        let secondFrame = try makePixelBuffer(width: 16, height: 8)
        let published = expectation(description: "Frame published")
        let identifier = store.addObserver { _, _ in
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
