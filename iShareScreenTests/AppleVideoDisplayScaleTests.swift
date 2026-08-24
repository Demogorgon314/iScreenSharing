import XCTest
@testable import iShareScreen

final class AppleVideoDisplayScaleTests: XCTestCase {
    func testTogglesBetweenFitAndActualSize() {
        var scale = AppleVideoDisplayScale()
        XCTAssertTrue(scale.scalesToFit)
        scale.toggleScaling()
        XCTAssertEqual(scale.fixedScale, 1)
        scale.toggleScaling()
        XCTAssertTrue(scale.scalesToFit)
    }

    func testSetsScaleToFitIdempotently() {
        var scale = AppleVideoDisplayScale(fixedScale: 1.5)

        scale.setScalesToFit(true)
        XCTAssertTrue(scale.scalesToFit)

        scale.setScalesToFit(true)
        XCTAssertTrue(scale.scalesToFit)

        scale.setScalesToFit(false)
        XCTAssertEqual(scale.fixedScale, 1)
    }

    func testZoomStartsAtActualSizeAndClampsToBounds() {
        var scale = AppleVideoDisplayScale()
        scale.zoomIn()
        XCTAssertEqual(scale.fixedScale, 1.25)
        for _ in 0..<20 { scale.zoomIn() }
        XCTAssertEqual(scale.fixedScale, AppleVideoDisplayScale.maximum)
        for _ in 0..<40 { scale.zoomOut() }
        XCTAssertEqual(scale.fixedScale, AppleVideoDisplayScale.minimum)
    }

    func testInitialFixedScaleIsClamped() {
        XCTAssertEqual(AppleVideoDisplayScale(fixedScale: 10).fixedScale, 4)
        XCTAssertEqual(AppleVideoDisplayScale(fixedScale: 0).fixedScale, 0.25)
    }
}
