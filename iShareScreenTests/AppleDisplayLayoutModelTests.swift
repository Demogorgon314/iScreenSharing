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
        XCTAssertEqual(model.displayID(for: 0), 1)
        XCTAssertEqual(model.displayID(for: 1), 2)
        XCTAssertNil(model.displayID(for: 2))
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

    func testMapsBackingPixelsIntoGlobalLogicalInputCoordinates() {
        let mapping = AppleDisplayInputMapping(
            backingFrame: CGRect(x: 3840, y: 0, width: 2880, height: 1800),
            logicalFrame: CGRect(x: 1920, y: 0, width: 1440, height: 900)
        )

        XCTAssertEqual(
            mapping.point(from: CGPoint(x: 1440, y: 900), isDisplayLocal: true)?.x,
            2640
        )
        XCTAssertEqual(
            mapping.point(from: CGPoint(x: 5280, y: 900), isDisplayLocal: false)?.x,
            2640
        )
        XCTAssertEqual(
            mapping.point(from: CGPoint(x: 1440, y: 900), isDisplayLocal: true)?.y,
            450
        )
    }

    func testMapsIndependentStreamsUsingTheirNegotiatedCanvasSizes() {
        let displayOne = AppleDisplayInputMapping(
            backingFrame: CGRect(x: 2880, y: 0, width: 3840, height: 2160),
            logicalFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            localBackingSize: CGSize(width: 2560, height: 1440)
        )
        let displayTwo = AppleDisplayInputMapping(
            backingFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            logicalFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
            localBackingSize: CGSize(width: 2560, height: 1440)
        )

        XCTAssertEqual(
            displayOne.point(from: CGPoint(x: 1280, y: 720), isDisplayLocal: true)?.x,
            2400
        )
        XCTAssertEqual(
            displayOne.point(from: CGPoint(x: 1280, y: 720), isDisplayLocal: true)?.y,
            540
        )
        XCTAssertEqual(
            displayTwo.point(from: CGPoint(x: 1280, y: 720), isDisplayLocal: true)?.x,
            480
        )
        XCTAssertEqual(
            displayTwo.point(from: CGPoint(x: 1280, y: 720), isDisplayLocal: true)?.y,
            270
        )
    }

    func testIgnoresIncompleteLayoutBeforeInitialDualDisplayLayout() {
        let model = AppleDisplayLayoutModel(expectedDisplayCount: 2)
        let first = AppleDisplayRect(displayID: 11, x: 200, y: 0, width: 300, height: 100)
        let second = AppleDisplayRect(displayID: 22, x: 0, y: 0, width: 200, height: 100)

        model.receive(AppleDisplayLayout(
            scaledWidth: 150,
            scaledHeight: 50,
            backingWidth: 300,
            backingHeight: 100,
            displays: [first]
        ))

        XCTAssertNil(model.layout)

        model.receive(AppleDisplayLayout(
            scaledWidth: 250,
            scaledHeight: 50,
            backingWidth: 500,
            backingHeight: 100,
            displays: [first, second]
        ))

        XCTAssertEqual(model.layout?.displays.map(\.displayID), [11, 22])
    }

    func testSortsChangedDualDisplayLayoutByLogicalFrame() {
        let model = AppleDisplayLayoutModel(expectedDisplayCount: 2)
        let first = AppleDisplayRect(
            displayID: 11,
            x: 0,
            y: 0,
            width: 200,
            height: 100,
            logicalX: 0,
            logicalY: 0,
            logicalWidth: 100,
            logicalHeight: 50
        )
        let second = AppleDisplayRect(
            displayID: 22,
            x: 200,
            y: 0,
            width: 300,
            height: 100,
            logicalX: 100,
            logicalY: 0,
            logicalWidth: 150,
            logicalHeight: 50
        )
        model.receive(AppleDisplayLayout(
            scaledWidth: 250,
            scaledHeight: 50,
            backingWidth: 500,
            backingHeight: 100,
            displays: [first, second]
        ))

        let movedFirst = AppleDisplayRect(
            displayID: 11,
            x: 300,
            y: 0,
            width: 200,
            height: 100,
            logicalX: 150,
            logicalY: 0,
            logicalWidth: 100,
            logicalHeight: 50
        )
        let movedSecond = AppleDisplayRect(
            displayID: 22,
            x: 0,
            y: 0,
            width: 300,
            height: 100,
            logicalX: 0,
            logicalY: 0,
            logicalWidth: 150,
            logicalHeight: 50
        )

        model.receive(AppleDisplayLayout(
            scaledWidth: 250,
            scaledHeight: 50,
            backingWidth: 500,
            backingHeight: 100,
            displays: [movedFirst, movedSecond]
        ))

        XCTAssertEqual(model.layout?.displays.map(\.displayID), [22, 11])
    }
}
