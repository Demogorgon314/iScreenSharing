import XCTest
@testable import iShareScreen

@MainActor
final class AppleNV24MetalLayerTests: XCTestCase {
    func testCreatesMetalRenderingContext() {
        XCTAssertNotNil(AppleNV24MetalContext())
    }

    func testConfiguresDisplaySyncWithoutTransactionPresentation() throws {
        let context = try XCTUnwrap(AppleNV24MetalContext())
        let layer = AppleNV24MetalLayer(context: context)

        XCTAssertTrue(layer.displaySyncEnabled)
        XCTAssertFalse(layer.presentsWithTransaction)

        layer.synchronizesPresentation = false
        XCTAssertFalse(layer.displaySyncEnabled)
        XCTAssertFalse(layer.presentsWithTransaction)
    }
}
