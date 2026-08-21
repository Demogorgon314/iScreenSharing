import XCTest
@testable import iShareScreen

final class AppleDynamicResolutionControllerTests: XCTestCase {
    func testRequestsDisplayConfigurationAndFramebufferRefresh() async throws {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        try await controller.request(width: 1440, height: 900)

        let messages = await recorder.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].first, 0x1d)
        XCTAssertEqual(messages[1], AppleRFBMessages.framebufferUpdateRequest())
    }

    func testChangedLayoutAppliesCanvasAndReoffersMedia() async throws {
        let recorder = MessageRecorder()
        let applied = CanvasRecorder()
        let controller = makeController(recorder: recorder, applied: applied)
        let layout = makeLayout(width: 2880, height: 1800)

        try await controller.receive(makeLayout(width: 1920, height: 1080))
        try await controller.receive(layout)

        let messages = await recorder.messages
        let canvases = await applied.canvases
        XCTAssertEqual(messages, [
            AppleRFBMessages.framebufferUpdateRequest(),
            AppleRFBMessages.framebufferUpdateRequest(), Data([0x1c, 0xaa]),
        ])
        XCTAssertEqual(canvases, [AppleCanvas(width: 2880, height: 1800, tileCount: 4)])
    }

    func testInitialLayoutOnlyRearmsFramebufferUpdatesEvenWhenItDiffers() async throws {
        let recorder = MessageRecorder()
        let applied = CanvasRecorder()
        let controller = makeController(recorder: recorder, applied: applied)

        try await controller.receive(makeLayout(width: 2880, height: 1800))

        let messages = await recorder.messages
        let canvases = await applied.canvases
        XCTAssertEqual(messages, [AppleRFBMessages.framebufferUpdateRequest()])
        XCTAssertTrue(canvases.isEmpty)
    }

    func testMediaAnswerUpdatesAuthoritativeTileCount() async {
        let recorder = MessageRecorder()
        let applied = CanvasRecorder()
        let controller = makeController(recorder: recorder, applied: applied)
        let canvas = AppleCanvas(width: 1920, height: 1080, tileCount: 2)

        await controller.receiveMediaCanvas(canvas)

        let appliedCanvas = await applied.firstCanvas()
        XCTAssertEqual(appliedCanvas, canvas)
    }

    func testRetriesMediaReofferAfterTransientFailure() async throws {
        let sender = FailingMediaSender()
        let applied = CanvasRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0xaa]),
            sendMessage: { message in try await sender.send(message) },
            applyCanvas: { canvas in await applied.append(canvas) }
        )
        let layout = makeLayout(width: 2880, height: 1800)

        try await controller.receive(makeLayout(width: 1920, height: 1080))
        do {
            try await controller.receive(layout)
            XCTFail("Expected the first media reoffer to fail")
        } catch { }
        try await controller.receive(layout)

        let attempts = await sender.mediaAttempts()
        let applyCount = await applied.count()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(applyCount, 1)
    }

    func testRejectsInvalidRequestBeforeSending() async {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        do {
            try await controller.request(width: 0, height: 900)
            XCTFail("Expected invalid dimensions")
        } catch {
            XCTAssertEqual(error as? AppleDisplayConfigurationError, .invalidDimensions)
        }
        let messages = await recorder.messages
        XCTAssertTrue(messages.isEmpty)
    }

    private func makeController(
        recorder: MessageRecorder,
        applied: CanvasRecorder = CanvasRecorder()
    ) -> AppleDynamicResolutionController {
        AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0xaa]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { canvas in await applied.append(canvas) }
        )
    }

    private func makeLayout(width: Int, height: Int) -> AppleDisplayLayout {
        AppleDisplayLayout(
            scaledWidth: width / 2,
            scaledHeight: height / 2,
            backingWidth: width,
            backingHeight: height,
            displays: [AppleDisplayRect(displayID: 1, x: 0, y: 0, width: width, height: height)]
        )
    }
}

private actor MessageRecorder {
    private(set) var messages = [Data]()

    func append(_ message: Data) {
        messages.append(message)
    }
}

private actor CanvasRecorder {
    private(set) var canvases = [AppleCanvas]()

    func append(_ canvas: AppleCanvas) {
        canvases.append(canvas)
    }

    func firstCanvas() -> AppleCanvas? { canvases.first }
    func count() -> Int { canvases.count }
}

private actor FailingMediaSender {
    private var attempts = 0

    func send(_ message: Data) throws {
        guard message.first == 0x1c else { return }
        attempts += 1
        if attempts == 1 { throw Failure.expected }
    }

    func mediaAttempts() -> Int { attempts }

    enum Failure: Error {
        case expected
    }
}
