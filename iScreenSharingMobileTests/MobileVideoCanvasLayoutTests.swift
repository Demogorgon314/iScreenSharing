import struct ScreenSharingProtocol.AppleCanvas
import XCTest
@testable import iScreenSharingMobile

final class MobileVideoCanvasLayoutTests: XCTestCase {
    func testFullCanvasPreservesAspectRatioAndCentersContent() {
        let canvas = AppleCanvas(width: 1920, height: 1080, tileCount: 4)

        let layout = AppleVideoCanvasLayout.fullCanvas(
            canvas: canvas,
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768)
        )

        XCTAssertEqual(layout.container.minX, 0, accuracy: 0.001)
        XCTAssertEqual(layout.container.minY, 96, accuracy: 0.001)
        XCTAssertEqual(layout.container.width, 1024, accuracy: 0.001)
        XCTAssertEqual(layout.container.height, 576, accuracy: 0.001)
    }

    func testRemotePointMapsUIKitTopLeftToRemoteTopLeft() {
        let canvas = AppleCanvas(width: 1920, height: 1080, tileCount: 4)
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)

        let topLeft = AppleVideoCanvasLayout.remotePoint(
            location: CGPoint(x: 0, y: 96),
            canvas: canvas,
            bounds: bounds
        )
        let bottomRight = AppleVideoCanvasLayout.remotePoint(
            location: CGPoint(x: 1023.9, y: 671.9),
            canvas: canvas,
            bounds: bounds
        )

        XCTAssertEqual(topLeft?.x, 0)
        XCTAssertEqual(topLeft?.y, 0)
        XCTAssertEqual(bottomRight?.x, 1919)
        XCTAssertEqual(bottomRight?.y, 1079)
    }

    func testRemotePointRejectsLetterboxArea() {
        let canvas = AppleCanvas(width: 1920, height: 1080, tileCount: 4)

        let point = AppleVideoCanvasLayout.remotePoint(
            location: CGPoint(x: 512, y: 40),
            canvas: canvas,
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768)
        )

        XCTAssertNil(point)
    }

    func testTilesCoverEveryNegotiatedTile() {
        let canvas = AppleCanvas(width: 1440, height: 900, tileCount: 4)

        let tiles = AppleVideoCanvasLayout.tiles(
            canvas: canvas,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.container.height }, 500, accuracy: 0.001)
        XCTAssertEqual(tiles[0].container.minY, 50, accuracy: 0.001)
        XCTAssertEqual(tiles[3].container.maxY, 550, accuracy: 0.001)
    }

    func testPortraitCanvasAlignsVideoToTop() {
        let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)

        let layout = AppleVideoCanvasLayout.fullCanvas(
            canvas: canvas,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        XCTAssertEqual(layout.container.minY, 0, accuracy: 0.001)
        XCTAssertEqual(layout.container.height, 300, accuracy: 0.001)
    }

    func testLocalPointMapsRemoteCursorIntoTopAlignedVideo() throws {
        let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)

        let point = try XCTUnwrap(AppleVideoCanvasLayout.localPoint(
            remoteX: 800,
            remoteY: 600,
            canvas: canvas,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800)
        ))

        XCTAssertEqual(point.x, 200, accuracy: 0.001)
        XCTAssertEqual(point.y, 150, accuracy: 0.001)
    }

    func testNativeTileContainersFollowRemoteTopToBottomOrder() {
        let canvasSize = CGSize(width: 1600, height: 1200)

        let first = AppleVideoCanvasLayout.nativeTileContainer(
            logicalStart: 0,
            validHeight: 300,
            canvasSize: canvasSize,
            width: 1600
        )
        let fourth = AppleVideoCanvasLayout.nativeTileContainer(
            logicalStart: 900,
            validHeight: 300,
            canvasSize: canvasSize,
            width: 1600
        )

        XCTAssertEqual(first.minY, 0, accuracy: 0.001)
        XCTAssertEqual(fourth.maxY, 1200, accuracy: 0.001)
    }

    func testZoomedTilesRemainContiguousAndCursorMapsBackToSameRemotePoint() throws {
        let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var viewport = MobileCanvasViewport()
        viewport.zoom(by: 2, around: CGPoint(x: 200, y: 150), translation: .zero, base: bounds, bounds: bounds)
        let full = AppleVideoCanvasLayout.fullCanvas(canvas: canvas, bounds: bounds, viewport: viewport)
        let tiles = AppleVideoCanvasLayout.tiles(canvas: canvas, bounds: bounds, viewport: viewport)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles.first?.container.minY, full.container.minY)
        XCTAssertEqual(tiles.last?.container.maxY, full.container.maxY)
        for index in 1..<tiles.count {
            XCTAssertEqual(tiles[index - 1].container.maxY, tiles[index].container.minY)
            XCTAssertEqual(tiles[index].container.width, full.container.width)
        }
        let local = try XCTUnwrap(AppleVideoCanvasLayout.localPoint(
            remoteX: 900, remoteY: 700, canvas: canvas, bounds: bounds, viewport: viewport
        ))
        let remote = AppleVideoCanvasLayout.remotePoint(
            location: viewport.unproject(local, base: bounds, bounds: bounds), canvas: canvas, bounds: bounds
        )
        XCTAssertEqual(remote?.x, 900)
        XCTAssertEqual(remote?.y, 700)
    }
}
