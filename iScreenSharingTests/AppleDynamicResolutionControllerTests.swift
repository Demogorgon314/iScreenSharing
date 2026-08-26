import XCTest
@testable import iScreenSharing

final class AppleDynamicResolutionControllerTests: XCTestCase {
    private let mediaConfiguration = Data([0x1c, 0, 0, 0])

    func testRequestsOnlyNativeDisplayConfiguration() async throws {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        try await controller.request(width: 1440, height: 900)

        let messages = await recorder.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].first, 0x1d)
    }

    func testFixedResolutionUses1080pLogicalSizeWithHiDPIBackingPixels() async throws {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        try await controller.requestFixedResolution()

        let messages = await recorder.messages
        let message = try XCTUnwrap(messages.first)
        let firstModeOffset = 12 + 0x9c
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset), 3_840)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset + 4), 2_160)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset + 8), 1_920)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset + 12), 1_080)
    }

    func testRequestsDifferentResolutionForEachDisplay() async throws {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        try await controller.request(displaySizes: [
            AppleDynamicResolutionSize(width: 1440, height: 900),
            AppleDynamicResolutionSize(width: 1200, height: 800),
        ])

        let messages = await recorder.messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(try messages[0].uint16BE(at: 6), 2)
        XCTAssertEqual(try messages[0].uint32BE(at: 12 + 0x9c), 2880)
        XCTAssertEqual(try messages[0].uint32BE(at: 308 + 0x9c), 2400)
    }

    func testReselectsCombinedCanvasAndRestartsMediaAfterLayout() async throws {
        let recorder = MessageRecorder()
        let controller = makeController(recorder: recorder)

        try await controller.receive(makeLayout(width: 1920, height: 1080))
        try await controller.request(displaySizes: [
            AppleDynamicResolutionSize(width: 1440, height: 900),
            AppleDynamicResolutionSize(width: 1200, height: 800),
        ])
        try await controller.receive(makeLayout(
            width: 5280,
            height: 1800,
            displays: [
                AppleDisplayRect(displayID: 1, x: 0, y: 0, width: 2880, height: 1800),
                AppleDisplayRect(displayID: 2, x: 2880, y: 0, width: 2400, height: 1600),
            ]
        ))

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.first), [0x03, 0x1d, 0x0d, 0x03, 0x1c])
        XCTAssertEqual(messages[2], AppleRFBMessages.selectCombinedDisplays)
        XCTAssertEqual(messages[4], mediaConfiguration)
    }

    func testChangedLayoutAppliesCanvasAndRestartsMedia() async throws {
        let recorder = MessageRecorder()
        let applied = CanvasRecorder()
        let restarts = MediaRestartRecorder()
        let controller = makeController(
            recorder: recorder,
            applied: applied,
            restarts: restarts
        )
        let layout = makeLayout(width: 2880, height: 1800)

        try await controller.receive(makeLayout(width: 1920, height: 1080))
        try await controller.receive(layout)

        let messages = await recorder.messages
        let canvases = await applied.canvases
        let restartCount = await restarts.count
        XCTAssertEqual(messages, [
            AppleRFBMessages.framebufferUpdateRequest(),
            AppleRFBMessages.framebufferUpdateRequest(),
            mediaConfiguration,
        ])
        XCTAssertEqual(canvases, [AppleCanvas(width: 2880, height: 1800, tileCount: 4)])
        XCTAssertEqual(restartCount, 1)
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

    func testRetriesMediaRestartAfterTransientSendFailure() async throws {
        let sender = FailingMediaSender()
        let applied = CanvasRecorder()
        let restarts = MediaRestartRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: mediaConfiguration,
            sendMessage: { message in try await sender.send(message) },
            applyCanvas: { canvas in await applied.append(canvas) },
            prepareMediaRestart: { await restarts.record() }
        )
        let layout = makeLayout(width: 2880, height: 1800)

        try await controller.receive(makeLayout(width: 1920, height: 1080))
        do {
            try await controller.receive(layout)
            XCTFail("Expected the first media restart to fail")
        } catch { }
        try await controller.receive(layout)

        let attemptCount = await sender.mediaAttempts
        let applyCount = await applied.count()
        let restartCount = await restarts.count
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(applyCount, 1)
        XCTAssertEqual(restartCount, 1)
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
        applied: CanvasRecorder = CanvasRecorder(),
        restarts: MediaRestartRecorder = MediaRestartRecorder()
    ) -> AppleDynamicResolutionController {
        AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: mediaConfiguration,
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { canvas in await applied.append(canvas) },
            prepareMediaRestart: { await restarts.record() }
        )
    }

    private func makeLayout(
        width: Int,
        height: Int,
        displays: [AppleDisplayRect]? = nil
    ) -> AppleDisplayLayout {
        AppleDisplayLayout(
            scaledWidth: width / 2,
            scaledHeight: height / 2,
            backingWidth: width,
            backingHeight: height,
            displays: displays ?? [
                AppleDisplayRect(displayID: 1, x: 0, y: 0, width: width, height: height),
            ]
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

private actor MediaRestartRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor FailingMediaSender {
    private(set) var mediaAttempts = 0

    func send(_ message: Data) throws {
        guard message.first == 0x1c else { return }
        mediaAttempts += 1
        if mediaAttempts == 1 { throw Failure.expected }
    }

    enum Failure: Error {
        case expected
    }
}
