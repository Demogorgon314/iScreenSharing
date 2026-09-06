import CoreGraphics
import XCTest
@testable import iScreenSharing

final class MobileInteractionStateTests: XCTestCase {
    @MainActor
    func testCancellationDropsQueuedMovementButReleasesAfterInFlightWrite() async {
        let queue = MobileInputQueue()
        let gate = InputTestGate()
        let started = expectation(description: "Pointer down started")
        var events = [String]()
        let drag = queue.enqueue {
            started.fulfill()
            await gate.wait()
            events.append("down")
        }
        queue.enqueue { events.append("stale move") }
        await fulfillment(of: [started], timeout: 1)
        drag.cancel()
        queue.cancelPending { events.append("up") }
        let next = queue.enqueue { events.append("new click") }
        await gate.open()
        await next.value
        XCTAssertEqual(events, ["down", "up", "new click"])
    }

    @MainActor
    func testRepeatedInterruptionsNeverDiscardReleaseBarrier() async {
        let queue = MobileInputQueue()
        var events = [String]()
        queue.enqueue { events.append("stale key") }
        queue.cancelPending { events.append("release one") }
        queue.enqueue { events.append("stale click") }
        queue.cancelPending { events.append("release two") }
        await queue.enqueue { events.append("new key") }.value
        XCTAssertEqual(events, ["release one", "release two", "new key"])
    }

    func testShortcutModifiersAreOneShotAndReleasedInReverseOrder() {
        var keyboard = MobileKeyboardState()
        keyboard.toggle(.command)
        keyboard.toggle(.shift)
        XCTAssertEqual(keyboard.consume(symbol: 0x63), [
            .init(symbol: 0xffeb, isDown: true), .init(symbol: 0xffe1, isDown: true),
            .init(symbol: 0x63, isDown: true), .init(symbol: 0x63, isDown: false),
            .init(symbol: 0xffe1, isDown: false), .init(symbol: 0xffeb, isDown: false),
        ])
        XCTAssertTrue(keyboard.modifiers.isEmpty)
        XCTAssertEqual(keyboard.consume(symbol: 0x76).count, 2)
        keyboard.toggle(.control)
        keyboard.toggle(.control)
        XCTAssertTrue(keyboard.modifiers.isEmpty)
        keyboard.toggle(.option)
        keyboard.reset()
        XCTAssertEqual(keyboard.consume(symbol: 0xff1b).count, 2)
    }

    func testNamedShortcutReplacesArmedModifiersAndReleasesAllKeys() {
        var keyboard = MobileKeyboardState()
        keyboard.toggle(.option)
        keyboard.toggle(.shift)
        XCTAssertEqual(keyboard.consume(symbol: 0x63, explicitModifiers: [.command]), [
            .init(symbol: 0xffeb, isDown: true),
            .init(symbol: 0x63, isDown: true), .init(symbol: 0x63, isDown: false),
            .init(symbol: 0xffeb, isDown: false),
        ])
        XCTAssertTrue(keyboard.modifiers.isEmpty)
        XCTAssertEqual(keyboard.consume(symbol: 0xffbe), [
            .init(symbol: 0xffbe, isDown: true), .init(symbol: 0xffbe, isDown: false),
        ])
    }

    func testScrollPreservesBothAxesAndFractionalRemainder() {
        var scroll = MobileScrollState()
        XCTAssertNil(scroll.consume(translation: CGPoint(x: 0.25, y: 0.25)))
        let first = scroll.consume(translation: CGPoint(x: 12, y: 2))
        XCTAssertEqual(first?.event.pointDeltaX, 12)
        XCTAssertEqual(first?.horizontalTicks, 1)
        XCTAssertEqual(first?.verticalTicks, 0)
        let second = scroll.consume(translation: CGPoint(x: 0.75, y: 9.75))
        XCTAssertEqual(second?.event.pointDeltaX, 1)
        XCTAssertEqual(second?.event.pointDeltaY, 10)
        XCTAssertEqual(second?.verticalTicks, 1)
        scroll.reset()
        XCTAssertNil(scroll.consume(translation: .zero))
        XCTAssertNil(scroll.consume(translation: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertEqual(scroll.consume(translation: CGPoint(x: 0, y: 120))?.verticalTicks, 10)
        scroll.reset()
        let upward = scroll.consume(translation: CGPoint(x: 0, y: -24))
        XCTAssertEqual(upward?.event.pointDeltaY, -24)
        XCTAssertEqual(upward?.verticalTicks, -2)
    }

    func testPixelScrollFieldsMatchCoreGraphicsOracle() throws {
        for value: Int32 in [0, 1, 5, 10, 12, 120, -1, -12, -120] {
            let native = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: value, wheel2: -value, wheel3: 0
            ))
            let event = MobileScrollState.pixelEvent(x: -value, y: value)
            XCTAssertEqual(Int64(event.deltaY), native.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            XCTAssertEqual(Int64(event.deltaX), native.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            XCTAssertEqual(Int64(event.fixedDeltaY), native.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1))
            XCTAssertEqual(Int64(event.fixedDeltaX), native.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2))
            XCTAssertEqual(Int64(event.pointDeltaY), native.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            XCTAssertEqual(Int64(event.pointDeltaX), native.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        }
    }
}

private actor InputTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
