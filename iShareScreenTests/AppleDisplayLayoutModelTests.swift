import XCTest
@testable import iShareScreen

@MainActor
final class AppleDisplayLayoutModelTests: XCTestCase {
    func testExpectedMultipleDisplaysDoNotSupportDynamicResolution() {
        let model = AppleDisplayLayoutModel(expectedDisplayCount: 2)

        XCTAssertEqual(model.displayCount, 2)
        XCTAssertFalse(model.supportsDynamicResolution)

        model.receive(AppleDisplayLayout(
            scaledWidth: 960,
            scaledHeight: 540,
            backingWidth: 1920,
            backingHeight: 1080,
            displays: [AppleDisplayRect(displayID: 1, x: 0, y: 0, width: 1920, height: 1080)]
        ))
        XCTAssertFalse(model.supportsDynamicResolution)
    }

    func testPublishesEachDisplayCropForMultiDisplayLayout() {
        let model = AppleDisplayLayoutModel()
        let layout = AppleDisplayLayout(
            scaledWidth: 1920,
            scaledHeight: 540,
            backingWidth: 3840,
            backingHeight: 1080,
            displays: [
                AppleDisplayRect(displayID: 1, x: 0, y: 0, width: 1920, height: 1080),
                AppleDisplayRect(displayID: 2, x: 1920, y: 0, width: 1920, height: 1080),
            ]
        )

        model.receive(layout)

        XCTAssertEqual(model.layout, layout)
        XCTAssertEqual(model.displayCount, 2)
        XCTAssertFalse(model.supportsDynamicResolution)
        XCTAssertEqual(model.sourceRect(for: 0), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.sourceRect(for: 1), CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.inputOrigin(for: 0), .zero)
        XCTAssertEqual(model.inputOrigin(for: 1), CGPoint(x: 1920, y: 0))
    }

    func testSingleDisplayUsesWholeCanvasAndSupportsDynamicResolution() {
        let model = AppleDisplayLayoutModel()
        model.receive(AppleDisplayLayout(
            scaledWidth: 960,
            scaledHeight: 540,
            backingWidth: 1920,
            backingHeight: 1080,
            displays: [AppleDisplayRect(displayID: 1, x: 0, y: 0, width: 1920, height: 1080)]
        ))

        XCTAssertNil(model.sourceRect(for: 0))
        XCTAssertTrue(model.supportsDynamicResolution)
    }
}
