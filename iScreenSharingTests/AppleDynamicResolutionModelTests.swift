import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import XCTest
@testable import iScreenSharing

final class AppleDynamicResolutionModelTests: XCTestCase {
    @MainActor
    func testIsEnabledByDefault() {
        XCTAssertTrue(AppleDynamicResolutionModel().isEnabled)
    }

    @MainActor
    func testIsDisabledForMultipleDisplays() {
        XCTAssertFalse(AppleDynamicResolutionModel(displayCount: 2).isEnabled)
    }

    @MainActor
    func testSwitchingModesRequestsFixedResolutionAndCanRestoreTheSameViewport() async throws {
        let firstDynamicRequest = expectation(description: "First dynamic resolution requested")
        let fixedRequest = expectation(description: "Fixed resolution requested")
        let restoredDynamicRequest = expectation(description: "Dynamic resolution restored")
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0, 0, 0]),
            sendMessage: { message in
                let count = await recorder.append(message)
                switch count {
                case 1: firstDynamicRequest.fulfill()
                case 2: fixedRequest.fulfill()
                case 3: restoredDynamicRequest.fulfill()
                default: break
                }
            },
            applyCanvas: { _ in },
            prepareMediaRestart: { }
        )
        let model = AppleDynamicResolutionModel(
            requestFixedResolution: { try await controller.requestFixedResolution() }
        )

        model.schedule(
            viewport: CGSize(width: 1_000, height: 700),
            controller: controller,
            waitsForViewportToSettle: false
        )
        await fulfillment(of: [firstDynamicRequest], timeout: 1)
        model.isEnabled = false
        await fulfillment(of: [fixedRequest], timeout: 1)
        model.isEnabled = true
        model.schedule(
            viewport: CGSize(width: 1_000, height: 700),
            controller: controller,
            waitsForViewportToSettle: false
        )
        await fulfillment(of: [restoredDynamicRequest], timeout: 1)

        let messages = await recorder.allMessages()
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(try messages[0].uint32BE(at: 12 + 0x9c), 2_000)
        XCTAssertEqual(try messages[1].uint32BE(at: 12 + 0x9c), 3_840)
        XCTAssertEqual(try messages[2].uint32BE(at: 12 + 0x9c), 2_000)
        XCTAssertNil(model.errorMessage)
    }

    func testNormalizesViewportToNativeProtocolBoundsWithoutAspectOrEvenAlignment() {
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 100.9, height: 200.1)),
            AppleDynamicResolutionSize(width: 800, height: 600)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 1201.9, height: 801.9)),
            AppleDynamicResolutionSize(width: 1201, height: 801)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 3000, height: 2000)),
            AppleDynamicResolutionSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 1, height: 10_000)),
            AppleDynamicResolutionSize(width: 800, height: 1080)
        )
    }

    @MainActor
    func testDoesNotRequestResolutionWhenCanvasAlreadyMatchesViewport() async throws {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 2000, height: 1400, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0, 0, 0]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in },
            prepareMediaRestart: { }
        )
        let model = AppleDynamicResolutionModel()

        model.schedule(
            viewport: CGSize(width: 1000, height: 700),
            canvas: AppleCanvas(width: 2000, height: 1400, tileCount: 4),
            controller: controller
        )
        try await Task.sleep(for: .milliseconds(600))
        let sentCount = await recorder.count()

        XCTAssertEqual(sentCount, 0)
    }

    func testRejectsEmptyAndNonFiniteViewports() {
        XCTAssertNil(AppleDynamicResolutionSize.normalized(viewport: .zero))
        XCTAssertNil(AppleDynamicResolutionSize.normalized(viewport: CGSize(width: CGFloat.infinity, height: 800)))
    }

    @MainActor
    func testDebouncesRequestAndCanCancelPendingWork() async throws {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0, 0, 0]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in },
            prepareMediaRestart: { }
        )
        let model = AppleDynamicResolutionModel()
        model.isEnabled = true
        model.schedule(viewport: CGSize(width: 1000, height: 700), controller: controller)

        try await Task.sleep(for: .milliseconds(650))
        let sentCount = await recorder.count()
        XCTAssertEqual(sentCount, 1)

        model.schedule(viewport: CGSize(width: 1200, height: 800), controller: controller)
        model.cancel()
        try await Task.sleep(for: .milliseconds(600))
        let finalCount = await recorder.count()
        XCTAssertEqual(finalCount, 1)
    }

    @MainActor
    func testCanSubmitSettledLiveResizeWithoutDebounce() async throws {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0, 0, 0]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in },
            prepareMediaRestart: { }
        )
        let model = AppleDynamicResolutionModel()

        model.schedule(
            viewport: CGSize(width: 1000, height: 700),
            controller: controller,
            waitsForViewportToSettle: false
        )

        try await Task.sleep(for: .milliseconds(100))
        let sentCount = await recorder.count()
        XCTAssertEqual(sentCount, 1)
    }

    @MainActor
    func testMultiDisplayResizeDoesNotRequestDynamicResolution() async {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 2_400, height: 1_600, tileCount: 4),
            mediaConfiguration: Data([0x1c, 0, 0, 0]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in },
            prepareMediaRestart: { }
        )
        let model = AppleDynamicResolutionModel(displayCount: 2)

        model.schedule(
            displayIndex: 1,
            viewport: CGSize(width: 1200, height: 800),
            controller: controller,
            waitsForViewportToSettle: false
        )

        let messageCount = await recorder.count()
        XCTAssertEqual(messageCount, 0)
    }
}

private actor DynamicResolutionMessageRecorder {
    private var messages = [Data]()

    @discardableResult
    func append(_ message: Data) -> Int {
        messages.append(message)
        return messages.count
    }
    func count() -> Int { messages.count }
    func allMessages() -> [Data] { messages }
}
