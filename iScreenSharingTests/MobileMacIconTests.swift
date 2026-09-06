import XCTest
@testable import iScreenSharing

final class MobileMacIconTests: XCTestCase {
    func testModernGenericIdentifiersResolveToDifferentHardwareFamilies() {
        XCTAssertEqual(MobileMacIcon.symbol(for: "Mac16,10"), "macmini")
        XCTAssertEqual(MobileMacIcon.symbol(for: "Mac16,9"), "macstudio")
        XCTAssertEqual(MobileMacIcon.symbol(for: "Mac16,6"), "laptopcomputer")
        XCTAssertEqual(MobileMacIcon.symbol(for: "Mac14,8"), "macpro.gen3")
        XCTAssertEqual(MobileMacIcon.symbol(for: "Mac16,2"), "desktopcomputer")
    }

    func testOlderIdentifiersAndMissingMetadataHaveSafeFallbacks() {
        XCTAssertEqual(MobileMacIcon.symbol(for: " MacBookAir10,1\n"), "laptopcomputer")
        XCTAssertEqual(MobileMacIcon.symbol(for: "Macmini9,1"), "macmini")
        XCTAssertEqual(MobileMacIcon.symbol(for: "MacPro6,1"), "macpro.gen2")
        for identifier in [nil, "", "UnknownMac999,999", "Mac99,1"] {
            XCTAssertEqual(MobileMacIcon.symbol(for: identifier), "desktopcomputer")
        }
    }
}
