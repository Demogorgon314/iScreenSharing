import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import enum ScreenSharingProtocol.AppleRFBMessages
import enum ScreenSharingProtocol.StandardRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.AppleScrollWheelEvent
import struct ScreenSharingProtocol.RFBServerInfo
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

    func testUsesHighPrecisionScrollWhenServerAdvertisesCommand23() async throws {
        let harness = try makeHighPerformanceHarness(supportsHighPrecisionScroll: true)
        let event = makeScrollEvent()

        await harness.input.scroll(event: event, x: 10, y: 20)

        XCTAssertEqual(harness.transport.sentMessages, [
            try harness.expectedRecordLayer.encrypt(
                AppleRFBMessages.scrollWheelEvent(event, x: 10, y: 20)
            ),
        ])
        harness.session.close()
    }

    func testFallsBackToScrollButtonsWithoutServerCommand23() async throws {
        let harness = try makeHighPerformanceHarness(supportsHighPrecisionScroll: false)

        await harness.input.scroll(event: makeScrollEvent(), x: 10, y: 20)

        var expectedMessages = [Data]()
        for button in [
            AppleInputController.scrollUp, 0,
            AppleInputController.scrollRight, 0,
        ] {
            let inputMessage = try harness.expectedRecordLayer.encryptPointerEvent(
                buttons: button,
                x: 10,
                y: 20,
                timestampDelta: 0
            )
            expectedMessages.append(try harness.expectedRecordLayer.encrypt(inputMessage))
        }
        XCTAssertEqual(harness.transport.sentMessages, expectedMessages)
        harness.session.close()
    }

    func testInputTimestampUsesWrappingMicrosecondDelta() {
        var timestamp = AppleInputTimestamp()

        XCTAssertEqual(timestamp.next(at: 0xffff_fff0), 0xffff_fff0)
        XCTAssertEqual(timestamp.next(at: 0x1_0000_0010), 0x20)
    }

    private func makeHighPerformanceHarness(
        supportsHighPrecisionScroll: Bool
    ) throws -> HighPerformanceInputHarness {
        let keys = try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16),
            initializationVector: Data(repeating: 0x22, count: 16)
        )
        var commandBitmap = Data(repeating: 0, count: 16)
        if supportsHighPrecisionScroll {
            commandBitmap[2] = 1
        }
        let transport = InputTestTransport()
        let endpoint = try ConnectionEndpoint("example.local")
        let address = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: 5900
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            masterKey: Data(),
            serverInfo: RFBServerInfo(
                width: 100,
                height: 100,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac",
                commandBitmap: commandBitmap
            ),
            transport: transport
        )
        session.install(recordLayer: AppleEncryptedRecordLayer(keys: keys))
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 100, height: 100, tileCount: 1),
            microseconds: { 0 }
        )
        session.install(inputController: input)
        return HighPerformanceInputHarness(
            session: session,
            transport: transport,
            input: input,
            expectedRecordLayer: AppleEncryptedRecordLayer(keys: keys)
        )
    }

    private func makeScrollEvent() -> AppleScrollWheelEvent {
        AppleScrollWheelEvent(
            deltaX: -1,
            deltaY: 2,
            deltaZ: 0,
            fixedDeltaX: 0,
            fixedDeltaY: 0,
            fixedDeltaZ: 0,
            pointDeltaX: -1,
            pointDeltaY: 2,
            pointDeltaZ: 0,
            scrollPhase: 1,
            momentumPhase: 0,
            scrollCount: 1,
            flags: 0
        )
    }
}

private struct HighPerformanceInputHarness {
    let session: RFBAuthenticatedSession
    let transport: InputTestTransport
    let input: AppleInputController
    let expectedRecordLayer: AppleEncryptedRecordLayer
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
