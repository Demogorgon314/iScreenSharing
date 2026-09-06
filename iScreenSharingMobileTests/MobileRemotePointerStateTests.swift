import struct ScreenSharingProtocol.AppleCanvas
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

    func testRelativeMovementDoesNotDependOnRemoteResolution() {
        var first = MobileRemotePointerState()
        var second = MobileRemotePointerState()

        let lowResolution = first.move(
            by: CGPoint(x: 10, y: -5),
            canvas: canvas,
            bounds: bounds
        )
        let highResolution = second.move(
            by: CGPoint(x: 10, y: -5),
            canvas: AppleCanvas(width: 3200, height: 2400, tileCount: 4),
            bounds: bounds
        )

        XCTAssertEqual(lowResolution.x - 800, 40)
        XCTAssertEqual(lowResolution.y - 600, -20)
        XCTAssertEqual(highResolution.x - 1_600, 40)
        XCTAssertEqual(highResolution.y - 1_200, -20)
    }

    func testDragPathSplitsLargeMovementIntoBoundedSteps() throws {
        let start = MobileRemotePointerState.Point(x: 100, y: 100)
        let end = MobileRemotePointerState.Point(x: 140, y: 130)

        let points = MobileRemotePointerPath.interpolatedPoints(from: start, to: end)

        XCTAssertEqual(points.last, end)
        var previous = start
        for point in points {
            XCTAssertLessThanOrEqual(
                hypot(Double(point.x - previous.x), Double(point.y - previous.y)),
                8.1
            )
            previous = point
        }
    }

    func testDragPathOmitsStationaryMovement() {
        let point = MobileRemotePointerState.Point(x: 100, y: 100)

        XCTAssertTrue(MobileRemotePointerPath.interpolatedPoints(
            from: point,
            to: point
        ).isEmpty)
    }

}
