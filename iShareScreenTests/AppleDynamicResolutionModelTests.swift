import XCTest
@testable import iShareScreen

final class AppleDynamicResolutionModelTests: XCTestCase {
    @MainActor
    func testIsEnabledByDefault() {
        XCTAssertTrue(AppleDynamicResolutionModel().isEnabled)
    }

    func testNormalizesViewportToEvenProtocolBounds() {
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 100.9, height: 200.1)),
            AppleDynamicResolutionSize(width: 320, height: 634)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 1201.9, height: 801.9)),
            AppleDynamicResolutionSize(width: 1200, height: 800)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 3000, height: 2000)),
            AppleDynamicResolutionSize(width: 1620, height: 1080)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 1, height: 10_000)),
            AppleDynamicResolutionSize(width: 2, height: 1080)
        )
    }

    @MainActor
    func testDoesNotRequestResolutionWhenCanvasAlreadyMatchesViewport() async throws {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 2000, height: 1400, tileCount: 4),
            mediaConfiguration: Data([0x1c]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in }
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
            mediaConfiguration: Data([0x1c]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in }
        )
        let model = AppleDynamicResolutionModel()
        model.isEnabled = true
        model.schedule(viewport: CGSize(width: 1000, height: 700), controller: controller)

        try await Task.sleep(for: .milliseconds(650))
        let sentCount = await recorder.count()
        XCTAssertEqual(sentCount, 2)

        model.schedule(viewport: CGSize(width: 1200, height: 800), controller: controller)
        model.cancel()
        try await Task.sleep(for: .milliseconds(600))
        let finalCount = await recorder.count()
        XCTAssertEqual(finalCount, 2)
    }

    @MainActor
    func testWaitsForBothDisplayViewportsAndRequestsThemTogether() async throws {
        let recorder = DynamicResolutionMessageRecorder()
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 3840, height: 1080, tileCount: 4),
            mediaConfiguration: Data([0x1c]),
            sendMessage: { message in await recorder.append(message) },
            applyCanvas: { _ in }
        )
        let model = AppleDynamicResolutionModel(displayCount: 2)

        model.schedule(
            displayIndex: 0,
            viewport: CGSize(width: 1000, height: 700),
            controller: controller
        )
        try await Task.sleep(for: .milliseconds(600))
        let incompleteRequestCount = await recorder.count()
        XCTAssertEqual(incompleteRequestCount, 0)

        model.schedule(
            displayIndex: 1,
            viewport: CGSize(width: 1200, height: 800),
            controller: controller
        )
        model.schedule(
            displayIndex: 1,
            viewport: CGSize(width: 1200, height: 800),
            controller: controller
        )
        try await Task.sleep(for: .milliseconds(600))

        let messages = await recorder.allMessages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(try messages[0].uint16BE(at: 6), 2)
        XCTAssertEqual(try messages[0].uint32BE(at: 12 + 0x9c + 8), 1000)
        XCTAssertEqual(try messages[0].uint32BE(at: 308 + 0x9c + 8), 1200)
    }
}

private actor DynamicResolutionMessageRecorder {
    private var messages = [Data]()

    func append(_ message: Data) { messages.append(message) }
    func count() -> Int { messages.count }
    func allMessages() -> [Data] { messages }
}
