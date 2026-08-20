import XCTest
@testable import iShareScreen

final class AppleInputControllerTests: XCTestCase {
    func testClampsPointerToCanvasAndWireCoordinateLimits() {
        let canvas = AppleCanvas(width: 70_000, height: 100, tileCount: 1)
        let low = AppleInputController.clampedPoint(x: -10, y: -1, canvas: canvas)
        let high = AppleInputController.clampedPoint(x: 80_000, y: 200, canvas: canvas)

        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)
        XCTAssertEqual(high.x, .max)
        XCTAssertEqual(high.y, 99)
    }
}
