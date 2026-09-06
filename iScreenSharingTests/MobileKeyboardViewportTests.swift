import XCTest
@testable import iScreenSharing

final class MobileKeyboardViewportTests: XCTestCase {
    func testDockedKeyboardUsesAreaAboveItAndHiddenKeyboardRestoresBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(
            MobileKeyboardViewport.availableBounds(in: bounds, avoiding: CGRect(x: 0, y: 450, width: 400, height: 350)),
            CGRect(x: 0, y: 0, width: 400, height: 450)
        )
        XCTAssertEqual(MobileKeyboardViewport.availableBounds(in: bounds, avoiding: .null), bounds)
        XCTAssertEqual(
            MobileKeyboardViewport.availableBounds(in: bounds, avoiding: CGRect(x: 0, y: 800, width: 400, height: 350)), bounds
        )
    }

    func testFloatingKeyboardCanLeaveMoreSpaceBesideItThanAboveIt() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let keyboard = CGRect(x: 700, y: 450, width: 300, height: 300)
        let available = MobileKeyboardViewport.availableBounds(in: bounds, avoiding: keyboard)
        XCTAssertEqual(available, CGRect(x: 0, y: 0, width: 700, height: 768))
        XCTAssertTrue(available.intersection(keyboard).isEmpty)
    }

    func testKeyboardReflowPreservesZoomAndRevealsPointer() {
        var viewport = MobileCanvasViewport()
        let original = CGRect(x: 0, y: 0, width: 400, height: 800)
        let base = CGRect(x: 0, y: 0, width: 400, height: 225)
        viewport.zoom(by: 3, around: CGPoint(x: 200, y: 100), translation: .zero, base: base, bounds: original)
        let available = MobileKeyboardViewport.availableBounds(
            in: original, avoiding: CGRect(x: 0, y: 350, width: 400, height: 450)
        )
        viewport.constrain(base: base, bounds: available)
        viewport.reveal(basePoint: CGPoint(x: 300, y: 180), base: base, bounds: available)
        let frame = viewport.frame(base: base, bounds: available)
        XCTAssertEqual(viewport.scale, 3)
        XCTAssertTrue(available.contains(CGPoint(x: frame.minX + 300 * 3, y: frame.minY + 180 * 3)))
    }

    func testKeyboardShrinkingAndHidingRestoresZoomedCanvasExtent() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let base = CGRect(x: 0, y: 0, width: 400, height: 225)
        var viewport = MobileCanvasViewport()
        viewport.zoom(by: 4, around: CGPoint(x: 200, y: 100), translation: .zero, base: base, bounds: bounds)

        // Reuse the same zoom/pan state across keyboard transitions, including
        // its offscreen end frame while the input view is still first responder.
        for keyboardTop: CGFloat in [350, 550, 800, 350, 800] {
            let available = MobileKeyboardViewport.availableBounds(
                in: bounds, avoiding: CGRect(x: 0, y: keyboardTop, width: 400, height: 450)
            )
            viewport.constrain(base: base, bounds: available)
            viewport.pan(by: CGPoint(x: 0, y: -1000), base: base, bounds: available)
            let frame = viewport.frame(base: base, bounds: available)
            XCTAssertEqual(viewport.scale, 4)
            XCTAssertEqual(frame.maxY, keyboardTop)
            XCTAssertEqual(frame.intersection(available).height, keyboardTop)
            let bottom = viewport.unproject(CGPoint(x: available.midX, y: available.maxY), base: base, bounds: available)
            XCTAssertEqual(bottom.y, base.maxY)
        }
    }

    func testCommittedTextNormalizesNewlinesAndConsumesModifierOnlyOnce() {
        var keyboard = MobileKeyboardState()
        keyboard.toggle(.command)
        let events = keyboard.consume(text: "c你\r\n\t😀")
        XCTAssertEqual(events.map(\.symbol), [
            0xffeb, 0x63, 0x63, 0xffeb,
            0x01004f60, 0x01004f60,
            0xff0d, 0xff0d, 0xff09, 0xff09,
            0x0101f600, 0x0101f600,
        ])
        XCTAssertTrue(keyboard.modifiers.isEmpty)
        XCTAssertTrue(keyboard.consume(text: "").isEmpty)
    }
}
