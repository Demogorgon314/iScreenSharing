import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import XCTest
@testable import iScreenSharing

final class AppleInputControllerTests: XCTestCase {
    func testStandardPointerRemapsAppleRightAndMiddleButtons() async throws {
        let transport = InputTestTransport()
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            sharingType: .standard,
            masterKey: Data(),
            serverInfo: RFBServerInfo(
                width: 100,
                height: 100,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 100, height: 100, tileCount: 1)
        )

        await input.pointer(
            buttons: AppleInputController.rightButton,
            x: 10,
            y: 20
        )
        await input.pointer(
            buttons: AppleInputController.middleButton,
            x: 30,
            y: 40
        )

        XCTAssertEqual(transport.sentMessages, [
            StandardRFBMessages.pointerEvent(buttons: 1 << 2, x: 10, y: 20),
            StandardRFBMessages.pointerEvent(buttons: 1 << 1, x: 30, y: 40),
        ])
    }

    func testClampsPointerToCanvasAndWireCoordinateLimits() {
        let canvas = AppleCanvas(width: 70_000, height: 100, tileCount: 1)
        let low = AppleInputController.clampedPoint(x: -10, y: -1, canvas: canvas)
        let high = AppleInputController.clampedPoint(x: 80_000, y: 200, canvas: canvas)

        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.y, 0)
        XCTAssertEqual(high.x, .max)
        XCTAssertEqual(high.y, 99)
    }

    func testSelectedDisplayCoordinatesAreNotClampedToCombinedCanvas() {
        let point = AppleInputController.clampedPoint(x: 3_020, y: 1_786, canvas: nil)

        XCTAssertEqual(point.x, 3_020)
        XCTAssertEqual(point.y, 1_786)

        let wireMaximum = AppleInputController.clampedPoint(x: 80_000, y: 80_000, canvas: nil)
        XCTAssertEqual(wireMaximum.x, .max)
        XCTAssertEqual(wireMaximum.y, .max)
    }

    func testDisplaySelectionOnlyEmitsWhenTargetChanges() {
        var selection = AppleInputDisplaySelection()

        XCTAssertNil(selection.message(for: nil))
        XCTAssertEqual(selection.message(for: 42), AppleRFBMessages.selectDisplay(42))
        XCTAssertNil(selection.message(for: 42))
        XCTAssertEqual(selection.message(for: 84), AppleRFBMessages.selectDisplay(84))
        XCTAssertEqual(selection.message(for: nil), AppleRFBMessages.selectCombinedDisplays)
        XCTAssertNil(selection.message(for: nil))
    }

    func testBuildsVerticalAndHorizontalFallbackScrollButtons() {
        XCTAssertEqual(
            AppleInputController.scrollButtons(verticalTicks: 2, horizontalTicks: -1),
            [
                AppleInputController.scrollUp, 0,
                AppleInputController.scrollRight, 0,
            ]
        )
        XCTAssertEqual(
            AppleInputController.scrollButtons(verticalTicks: -1, horizontalTicks: 1),
            [
                AppleInputController.scrollDown, 0,
                AppleInputController.scrollLeft, 0,
            ]
        )
        XCTAssertEqual(
            AppleInputController.scrollButtons(verticalTicks: 50, horizontalTicks: -50),
            [
                AppleInputController.scrollUp, 0,
                AppleInputController.scrollRight, 0,
            ]
        )
    }

    func testInputTimestampUsesWrappingMicrosecondDelta() {
        var timestamp = AppleInputTimestamp()

        XCTAssertEqual(timestamp.next(at: 0xffff_fff0), 0xffff_fff0)
        XCTAssertEqual(timestamp.next(at: 0x1_0000_0010), 0x20)
    }
}

private final class InputTestTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = [Data]()

    var sentMessages: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        lock.lock()
        sent.append(data)
        lock.unlock()
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() { }
}
