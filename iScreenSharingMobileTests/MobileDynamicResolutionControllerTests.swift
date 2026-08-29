import XCTest
@testable import iScreenSharingMobile

final class MobileDynamicResolutionControllerTests: XCTestCase {
    func testManualRequestRestartsMediaWhenHostReturnsUnchangedCanvas() async throws {
        let messages = MobileResolutionMessageRecorder()
        let restarts = MobileResolutionRestartRecorder()
        let mediaConfiguration = Data([0x1c, 0, 0, 0])
        let controller = AppleDynamicResolutionController(
            initialCanvas: AppleCanvas(width: 1600, height: 1200, tileCount: 4),
            mediaConfiguration: mediaConfiguration,
            sendMessage: { message in await messages.append(message) },
            applyCanvas: { _ in },
            prepareMediaRestart: { await restarts.record() }
        )
        let unchangedLayout = AppleDisplayLayout(
            scaledWidth: 800,
            scaledHeight: 600,
            backingWidth: 1600,
            backingHeight: 1200,
            displays: [AppleDisplayRect(
                displayID: 1,
                x: 0,
                y: 0,
                width: 1600,
                height: 1200
            )]
        )

        try await controller.receive(unchangedLayout)
        try await controller.request(width: 1280, height: 720)
        try await controller.receive(unchangedLayout)

        let sent = await messages.messages
        let restartCount = await restarts.count
        XCTAssertEqual(sent.map(\.first), [0x03, 0x1d, 0x03, 0x1c])
        XCTAssertEqual(restartCount, 1)
    }
}

private actor MobileResolutionMessageRecorder {
    private(set) var messages = [Data]()

    func append(_ message: Data) {
        messages.append(message)
    }
}

private actor MobileResolutionRestartRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
