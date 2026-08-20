import XCTest
@testable import iShareScreen

final class AppleDynamicResolutionModelTests: XCTestCase {
    func testNormalizesViewportToEvenProtocolBounds() {
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 100.9, height: 200.1)),
            AppleDynamicResolutionSize(width: 640, height: 480)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 1201.9, height: 801.9)),
            AppleDynamicResolutionSize(width: 1200, height: 800)
        )
        XCTAssertEqual(
            AppleDynamicResolutionSize.normalized(viewport: CGSize(width: 3000, height: 2000)),
            AppleDynamicResolutionSize(width: 1920, height: 1080)
        )
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
}

private actor DynamicResolutionMessageRecorder {
    private var messages = [Data]()

    func append(_ message: Data) { messages.append(message) }
    func count() -> Int { messages.count }
}
