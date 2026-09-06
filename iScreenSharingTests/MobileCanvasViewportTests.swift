import struct ScreenSharingProtocol.AppleCanvas
import XCTest
@testable import iScreenSharing

final class MobileCanvasViewportTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testZoomPreservesAnchorAndPointerScreenDistance() {
        var viewport = MobileCanvasViewport()
        let anchor = CGPoint(x: 180, y: 120)
        viewport.zoom(by: 2, around: anchor, translation: .zero, base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), CGRect(x: -180, y: -120, width: 800, height: 600))
        XCTAssertEqual(viewport.unproject(anchor, base: bounds, bounds: bounds), anchor)
        let canvas = AppleCanvas(width: 1600, height: 1200, tileCount: 4)
        var pointer = MobileRemotePointerState()
        let start = pointer.currentPoint(canvas: canvas)
        let end = pointer.move(
            by: viewport.unscaledTranslation(CGPoint(x: 12, y: -6)), canvas: canvas, bounds: bounds
        )
        let displayScale = bounds.width / CGFloat(canvas.width) * viewport.scale
        XCTAssertEqual(CGFloat(end.x - start.x) * displayScale, 12)
        XCTAssertEqual(CGFloat(end.y - start.y) * displayScale, -6)
    }

    func testPanClampsAtEveryEdgeAndResetRestoresFit() {
        var viewport = MobileCanvasViewport()
        viewport.zoom(by: 2, around: .zero, translation: .zero, base: bounds, bounds: bounds)
        viewport.pan(by: CGPoint(x: -10_000, y: -10_000), base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), CGRect(x: -400, y: -300, width: 800, height: 600))
        viewport.pan(by: CGPoint(x: 20_000, y: 20_000), base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), CGRect(x: 0, y: 0, width: 800, height: 600))
        viewport.reset()
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), bounds)
    }

    func testPortraitRetainsTopAlignmentAndReclampsAfterResize() {
        var viewport = MobileCanvasViewport()
        let portrait = CGRect(x: 0, y: 0, width: 400, height: 800)
        let base = CGRect(x: 0, y: 0, width: 400, height: 225)
        viewport.zoom(by: 2, around: CGPoint(x: 200, y: 100), translation: .zero, base: base, bounds: portrait)
        XCTAssertEqual(viewport.frame(base: base, bounds: portrait).minY, 0)
        viewport.pan(by: CGPoint(x: -1000, y: -1000), base: base, bounds: portrait)
        let smaller = CGRect(x: 0, y: 0, width: 200, height: 300)
        let smallerBase = CGRect(x: 0, y: 0, width: 200, height: 112.5)
        viewport.constrain(base: smallerBase, bounds: smaller)
        XCTAssertEqual(viewport.frame(base: smallerBase, bounds: smaller), CGRect(x: -200, y: 0, width: 400, height: 225))
    }

    func testOverlayFitZoomPointerRevealAndResetShareOneCoordinateSpace() {
        let bounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        var viewport = MobileCanvasViewport(topContentInset: 102)
        let base = CGRect(x: 0, y: 102, width: 414, height: 233)
        XCTAssertEqual(viewport.frame(base: base, bounds: bounds), base)
        let anchor = CGPoint(x: 207, y: 210)
        let original = viewport.unproject(anchor, base: base, bounds: bounds)
        viewport.zoom(by: 2, around: anchor, translation: .zero, base: base, bounds: bounds)
        XCTAssertLessThan(viewport.frame(base: base, bounds: bounds).minY, 102)
        let projected = viewport.unproject(anchor, base: base, bounds: bounds)
        XCTAssertEqual(projected.x, original.x, accuracy: 0.001)
        // Clamp can stop anchor preservation at the screen boundary.
        XCTAssertGreaterThanOrEqual(viewport.frame(base: base, bounds: bounds).minY, bounds.minY)
        viewport.reveal(basePoint: base.origin, base: base, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: base, bounds: bounds).minY, 102)
        viewport.reset()
        XCTAssertEqual(viewport.frame(base: base, bounds: bounds), base)
        XCTAssertEqual(viewport.topContentInset, 102)
    }

    func testOverlayInsetAdaptsToKeyboardAndRotationWithoutLosingZoom() {
        var viewport = MobileCanvasViewport(topContentInset: 102)
        let portrait = CGRect(x: 0, y: 0, width: 414, height: 896)
        let base = CGRect(x: 0, y: 102, width: 414, height: 233)
        viewport.zoom(by: 3, around: base.origin, translation: .zero, base: base, bounds: portrait)
        for height: CGFloat in [456, 896, 456, 896] {
            let available = CGRect(x: 0, y: 0, width: 414, height: height)
            viewport.constrain(base: base, bounds: available)
            XCTAssertEqual(viewport.fittingBounds(in: available).height, height - 102)
            XCTAssertEqual(viewport.scale, 3)
        }
        viewport.topContentInset = 44
        let landscape = CGRect(x: 0, y: 0, width: 896, height: 414)
        XCTAssertEqual(viewport.fittingBounds(in: landscape), CGRect(x: 0, y: 44, width: 896, height: 370))
        viewport.reset()
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.topContentInset, 44)
    }

    func testZoomLimitsAndInvalidInputDoNotCorruptGeometry() {
        var viewport = MobileCanvasViewport()
        viewport.zoom(by: 100, around: .zero, translation: .zero, base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.scale, 4)
        let previous = viewport.frame(base: bounds, bounds: bounds)
        viewport.zoom(by: .nan, around: .zero, translation: .zero, base: bounds, bounds: bounds)
        viewport.pan(by: CGPoint(x: CGFloat.infinity, y: 0), base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), previous)
        viewport.zoom(by: 0.01, around: .zero, translation: .zero, base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds), bounds)
    }

    func testParallelFingersScrollAndNeverSwitchToZoomMidGesture() throws {
        var gesture = MobileTwoFingerGestureState()
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        XCTAssertNil(gesture.update(first: CGPoint(x: 50, y: 52), second: CGPoint(x: 150, y: 52)))
        let start = try XCTUnwrap(gesture.update(first: CGPoint(x: 50, y: 60), second: CGPoint(x: 150, y: 60)))
        XCTAssertEqual(start.mode, .scrolling)
        XCTAssertEqual(start.translation, CGPoint(x: 0, y: 10))
        let later = try XCTUnwrap(gesture.update(first: CGPoint(x: 0, y: 70), second: CGPoint(x: 200, y: 70)))
        XCTAssertEqual(later.mode, .scrolling)
        XCTAssertEqual(later.translation, CGPoint(x: 0, y: 10))
    }

    func testPinchLocksToZoomAndNewContactCanScroll() throws {
        var gesture = MobileTwoFingerGestureState()
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        let start = try XCTUnwrap(gesture.update(first: CGPoint(x: 30, y: 50), second: CGPoint(x: 170, y: 50)))
        XCTAssertEqual(start.mode, .zooming)
        XCTAssertEqual(start.scale, 1.4, accuracy: 0.001)
        XCTAssertEqual(start.anchor, CGPoint(x: 100, y: 50))
        let later = try XCTUnwrap(gesture.update(first: CGPoint(x: 30, y: 90), second: CGPoint(x: 170, y: 90)))
        XCTAssertEqual(later.mode, .zooming)
        XCTAssertEqual(later.translation.y, 40)
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        XCTAssertEqual(gesture.update(first: CGPoint(x: 50, y: 40), second: CGPoint(x: 150, y: 40))?.mode, .scrolling)
        gesture.begin(first: .zero, second: .zero)
        XCTAssertNil(gesture.update(first: .zero, second: CGPoint(x: 100, y: 0)))
    }

    func testPointerFollowingMovesOnlyAtEdgesAndStopsAtDesktopBoundary() {
        var viewport = MobileCanvasViewport()
        XCTAssertFalse(viewport.reveal(basePoint: CGPoint(x: 400, y: 300), base: bounds, bounds: bounds))
        viewport.zoom(by: 2, around: CGPoint(x: 200, y: 150), translation: .zero, base: bounds, bounds: bounds)
        XCTAssertFalse(viewport.reveal(basePoint: CGPoint(x: 200, y: 150), base: bounds, bounds: bounds))
        XCTAssertTrue(viewport.reveal(basePoint: CGPoint(x: 300, y: 225), base: bounds, bounds: bounds))
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds).origin, CGPoint(x: -224, y: -174))
        // Continued pointer movement pans by precisely the screen-space delta.
        viewport.reveal(basePoint: CGPoint(x: 305, y: 230), base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds).origin, CGPoint(x: -234, y: -184))
        viewport.reveal(basePoint: CGPoint(x: 400, y: 300), base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds).origin, CGPoint(x: -400, y: -300))
        XCTAssertFalse(viewport.reveal(basePoint: CGPoint(x: 400, y: 300), base: bounds, bounds: bounds))
        viewport.reveal(basePoint: .zero, base: bounds, bounds: bounds)
        XCTAssertEqual(viewport.frame(base: bounds, bounds: bounds).origin, .zero)
    }

    func testStationaryFingerPinchDoesNotBecomeScroll() {
        var gesture = MobileTwoFingerGestureState()
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        // One finger anchors the screen while the other opens the pinch.
        XCTAssertNil(gesture.update(first: CGPoint(x: 30, y: 50), second: CGPoint(x: 150, y: 50), timestamp: 1))
        XCTAssertEqual(gesture.update(first: CGPoint(x: 28, y: 50), second: CGPoint(x: 150, y: 50), timestamp: 1.05)?.mode, .zooming)
    }

    func testLeadingScrollFingerGetsTimeForSecondFingerToJoin() {
        var gesture = MobileTwoFingerGestureState()
        gesture.begin(first: CGPoint(x: 100, y: 100), second: CGPoint(x: 100, y: 200))
        XCTAssertNil(gesture.update(first: CGPoint(x: 100, y: 108), second: CGPoint(x: 100, y: 200), timestamp: 1))
        let joined = gesture.update(first: CGPoint(x: 100, y: 112), second: CGPoint(x: 100, y: 208), timestamp: 1.016)
        XCTAssertEqual(joined?.mode, .scrolling)
        XCTAssertEqual(joined?.translation.y, 10)
    }

    func testClearPinchAndScrollRecognizeSmallMotionWithoutSettlingDelay() {
        var gesture = MobileTwoFingerGestureState()
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        XCTAssertEqual(gesture.update(first: CGPoint(x: 47, y: 50), second: CGPoint(x: 153, y: 50))?.mode, .zooming)
        gesture.begin(first: CGPoint(x: 50, y: 50), second: CGPoint(x: 150, y: 50))
        XCTAssertEqual(gesture.update(first: CGPoint(x: 50, y: 54), second: CGPoint(x: 150, y: 54))?.mode, .scrolling)
    }
}
