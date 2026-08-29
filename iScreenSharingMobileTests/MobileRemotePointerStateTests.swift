import XCTest
@testable import iScreenSharingMobile

final class MobileRemotePointerStateTests: XCTestCase {
    private let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

    func testStartsAtRemoteCanvasCenter() {
        var state = MobileRemotePointerState()

        XCTAssertEqual(state.currentPoint(canvas: canvas), .init(x: 800, y: 600))
    }

    func testLocalDragMovesRemotePointerRelatively() {
        var state = MobileRemotePointerState()

        let point = state.move(
            by: CGPoint(x: 10, y: -5),
            canvas: canvas,
            bounds: bounds
        )

        XCTAssertEqual(point, .init(x: 840, y: 580))
    }

    func testRelativeMovementClampsToCanvasEdges() {
        var state = MobileRemotePointerState()

        let point = state.move(
            by: CGPoint(x: 10_000, y: -10_000),
            canvas: canvas,
            bounds: bounds
        )

        XCTAssertEqual(point, .init(x: 1599, y: 0))
    }

    func testAbsoluteHoverIgnoresLetterboxAndMapsVideoCoordinates() {
        var state = MobileRemotePointerState()

        XCTAssertNil(state.setAbsolute(
            localPoint: CGPoint(x: 200, y: 500),
            canvas: canvas,
            bounds: bounds
        ))
        XCTAssertEqual(
            state.setAbsolute(
                localPoint: CGPoint(x: 200, y: 150),
                canvas: canvas,
                bounds: bounds
            ),
            .init(x: 800, y: 600)
        )
    }
}
