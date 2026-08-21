import XCTest
@testable import iShareScreen

final class AppleVideoCanvasLayoutTests: XCTestCase {
    func testIndependentDisplayInputWaitsForDisplayMapping() {
        XCTAssertNil(RemoteVideoCanvasNSView.mappedInputPoint(
            (x: 100, y: 200),
            mapping: nil,
            requiresDisplayMapping: true
        ))

        let mapping = AppleDisplayInputMapping(
            backingFrame: CGRect(x: 2_000, y: 0, width: 1_000, height: 800),
            logicalFrame: CGRect(x: 1_000, y: 0, width: 500, height: 400),
            localSourceSize: CGSize(width: 1_000, height: 800)
        )
        let point = RemoteVideoCanvasNSView.mappedInputPoint(
            (x: 100, y: 200),
            mapping: mapping,
            requiresDisplayMapping: true
        )

        XCTAssertEqual(point?.x, 2_100)
        XCTAssertEqual(point?.y, 200)
    }

    func testStacksDecodedTilesAndCropsOnlyCanvasOverflow() throws {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 1920, height: 1200, tileCount: 4),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 600),
            slotHeight: 304,
            fixedScale: nil
        )

        XCTAssertEqual(layouts.count, 4)
        XCTAssertEqual(layouts[0].container, CGRect(x: 0, y: 448, width: 960, height: 152))
        XCTAssertEqual(layouts[0].content, CGRect(x: 0, y: 0, width: 960, height: 152))
        XCTAssertEqual(layouts[2].container, CGRect(x: 0, y: 144, width: 960, height: 152))
        XCTAssertEqual(layouts[3].container, CGRect(x: 0, y: 0, width: 960, height: 144))
        XCTAssertEqual(layouts[3].content, CGRect(x: 0, y: -8, width: 960, height: 152))
    }

    func testUsesEachDecodedTileHeightForFollowingTileOrigin() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 1920, height: 1200, tileCount: 4),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 600),
            slotHeights: [304, 304, 304, 320],
            fixedScale: nil
        )

        XCTAssertEqual(layouts[0].content, CGRect(x: 0, y: 0, width: 960, height: 152))
        XCTAssertEqual(layouts[2].container, CGRect(x: 0, y: 144, width: 960, height: 152))
        XCTAssertEqual(layouts[3].container, CGRect(x: 0, y: 0, width: 960, height: 144))
        XCTAssertEqual(layouts[3].content, CGRect(x: 0, y: -16, width: 960, height: 160))
    }

    func testCentersCanvasWhenShowingActualSize() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 100, height: 80, tileCount: 2),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            slotHeight: 40,
            fixedScale: 1
        )

        XCTAssertEqual(layouts[0].container, CGRect(x: 100, y: 100, width: 100, height: 40))
        XCTAssertEqual(layouts[1].container, CGRect(x: 100, y: 60, width: 100, height: 40))
    }

    func testMapsLetterboxedViewCoordinatesIntoTopOriginCanvas() {
        let canvas = AppleCanvas(width: 100, height: 50, tileCount: 1)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let center = AppleVideoCanvasLayout.remotePoint(
            location: CGPoint(x: 150, y: 150),
            canvas: canvas,
            bounds: bounds,
            fixedScale: nil
        )

        XCTAssertEqual(center?.x, 50)
        XCTAssertEqual(center?.y, 25)
        XCTAssertNil(
            AppleVideoCanvasLayout.remotePoint(
                location: CGPoint(x: 150, y: 20),
                canvas: canvas,
                bounds: bounds,
                fixedScale: nil
            )
        )
    }

    func testCropsRightDisplayFromCombinedCanvas() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 3840, height: 1080, tileCount: 1),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 540),
            slotHeight: 1080,
            fixedScale: nil,
            sourceRect: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(layouts, [
            AppleVideoCanvasLayout.Tile(
                container: CGRect(x: 0, y: 0, width: 960, height: 540),
                content: CGRect(x: -960, y: 0, width: 1920, height: 540)
            ),
        ])
    }

    func testMapsCroppedDisplayCoordinatesIntoCombinedCanvas() {
        let point = AppleVideoCanvasLayout.remotePoint(
            location: CGPoint(x: 480, y: 270),
            canvas: AppleCanvas(width: 3840, height: 1080, tileCount: 1),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 540),
            fixedScale: nil,
            sourceRect: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(point?.x, 2880)
        XCTAssertEqual(point?.y, 540)
    }

    func testCropsBottomDisplayFromVerticallyTiledCanvas() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 1920, height: 2160, tileCount: 2),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 540),
            slotHeight: 1080,
            fixedScale: nil,
            sourceRect: CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        )

        XCTAssertEqual(layouts[0], AppleVideoCanvasLayout.Tile(container: .zero, content: .zero))
        XCTAssertEqual(
            layouts[1],
            AppleVideoCanvasLayout.Tile(
                container: CGRect(x: 0, y: 0, width: 960, height: 540),
                content: CGRect(x: 0, y: 0, width: 960, height: 540)
            )
        )
    }

    func testHidesAllTilesWhenDisplayCropIsOutsideCanvas() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 2),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 540),
            slotHeight: 540,
            fixedScale: nil,
            sourceRect: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        )

        XCTAssertEqual(
            layouts,
            Array(repeating: AppleVideoCanvasLayout.Tile(container: .zero, content: .zero), count: 2)
        )
    }
}
