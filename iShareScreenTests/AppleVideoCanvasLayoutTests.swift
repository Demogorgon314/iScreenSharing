import XCTest
@testable import iShareScreen

final class AppleVideoCanvasLayoutTests: XCTestCase {
    func testStacksPaddedTilesAndCropsFinalTileToCanvas() throws {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 1920, height: 1200, tileCount: 4),
            bounds: CGRect(x: 0, y: 0, width: 960, height: 600),
            slotHeight: 304,
            scalesToFit: true
        )

        XCTAssertEqual(layouts.count, 4)
        XCTAssertEqual(layouts[0].container, CGRect(x: 0, y: 448, width: 960, height: 152))
        XCTAssertEqual(layouts[2].container, CGRect(x: 0, y: 144, width: 960, height: 152))
        XCTAssertEqual(layouts[3].container, CGRect(x: 0, y: 0, width: 960, height: 144))
        XCTAssertEqual(layouts[3].content, CGRect(x: 0, y: -8, width: 960, height: 152))
    }

    func testCentersCanvasWhenShowingActualSize() {
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: AppleCanvas(width: 100, height: 80, tileCount: 2),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            slotHeight: 40,
            scalesToFit: false
        )

        XCTAssertEqual(layouts[0].container, CGRect(x: 100, y: 100, width: 100, height: 40))
        XCTAssertEqual(layouts[1].container, CGRect(x: 100, y: 60, width: 100, height: 40))
    }
}
