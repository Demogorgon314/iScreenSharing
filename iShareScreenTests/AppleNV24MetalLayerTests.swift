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
        XCTAssertEqual(layer.maximumDrawableCount, 2)
        XCTAssertTrue(layer.allowsNextDrawableTimeout)

        layer.synchronizesPresentation = false
        XCTAssertFalse(layer.displaySyncEnabled)
        XCTAssertFalse(layer.presentsWithTransaction)
    }

    func testVideoCanvasUsesOneMetalLayerForAllTiles() {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )

        XCTAssertEqual(
            view.layer?.sublayers?.filter { $0 is AppleNV24MetalLayer }.count,
            1
        )
    }

    func testVideoCanvasUsesMetalLayerSynchronization() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let metalLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? AppleNV24MetalLayer }.first
        )

        XCTAssertTrue(metalLayer.displaySyncEnabled)

        view.synchronizesPresentation = false
        XCTAssertFalse(metalLayer.displaySyncEnabled)
    }
}
