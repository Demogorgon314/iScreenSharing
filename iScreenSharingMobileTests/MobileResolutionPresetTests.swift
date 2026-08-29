import XCTest
@testable import iScreenSharingMobile

final class MobileResolutionPresetTests: XCTestCase {
    func testFitScreenUsesEvenViewportDimensions() {
        XCTAssertEqual(
            MobileResolutionPreset.fitScreen.size(for: CGSize(width: 413.9, height: 759.9)),
            AppleDynamicResolutionSize(width: 412, height: 758)
        )
    }

    func testFixedPresetsUseAdvertisedLogicalSizes() {
        let viewport = CGSize(width: 400, height: 800)

        XCTAssertEqual(
            MobileResolutionPreset.hd.size(for: viewport),
            AppleDynamicResolutionSize(width: 1280, height: 720)
        )
        XCTAssertEqual(
            MobileResolutionPreset.workspace.size(for: viewport),
            AppleDynamicResolutionSize(width: 1440, height: 900)
        )
        XCTAssertEqual(
            MobileResolutionPreset.fullHD.size(for: viewport),
            .fixed1080p
        )
    }
}
