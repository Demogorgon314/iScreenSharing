import struct ScreenSharingProtocol.AppleCursorImage
import XCTest
@testable import iScreenSharing

final class AppleCursorStoreTests: XCTestCase {
    func testStoresSelectsAndFallsBackForUnknownCursor() {
        let store = AppleCursorStore()
        let image = makeImage(value: 7)

        store.apply(.store(id: 42, image: image))
        XCTAssertEqual(store.currentImage(), image)
        store.apply(.select(id: 99))
        XCTAssertNil(store.currentImage())
        store.apply(.select(id: 42))
        XCTAssertEqual(store.currentImage(), image)
        XCTAssertEqual(store.receivedUpdateCount, 3)
    }

    func testEvictsOldestCursorAfterCacheLimit() {
        let store = AppleCursorStore()
        for id in 0..<65 {
            store.apply(.store(id: UInt32(id), image: makeImage(value: UInt8(id))))
        }

        store.apply(.select(id: 0))
        XCTAssertNil(store.currentImage())
        store.apply(.select(id: 64))
        XCTAssertEqual(store.currentImage(), makeImage(value: 64))
    }

    @MainActor
    func testPublishesCursorChangesAndRemovesObserver() async {
        let store = AppleCursorStore()
        let published = expectation(description: "cursor published")
        let image = makeImage(value: 9)
        let observer = store.addObserver { received in
            XCTAssertEqual(received, image)
            published.fulfill()
        }

        store.apply(.store(id: 1, image: image))
        await fulfillment(of: [published], timeout: 1)
        store.removeObserver(observer)
        store.apply(.select(id: 1))
    }

    private func makeImage(value: UInt8) -> AppleCursorImage {
        AppleCursorImage(
            width: 1,
            height: 1,
            hotspotX: 0,
            hotspotY: 0,
            rgba: Data([value, value, value, 255])
        )
    }
}
