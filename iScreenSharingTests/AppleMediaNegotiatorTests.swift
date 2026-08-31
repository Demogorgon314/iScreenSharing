import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import XCTest
@testable import iScreenSharing

final class AppleMediaNegotiatorTests: XCTestCase {
    func testFramebufferStartupRequestsInitialAndAutomaticUpdates() {
        XCTAssertEqual(
            AppleMediaNegotiator.framebufferStartupMessages(),
            [
                AppleRFBMessages.framebufferUpdateRequest(),
                AppleRFBMessages.autoFramebufferUpdate(),
            ]
        )
    }

    func testDualMediaStreamsKeepVirtualDisplayOrder() {
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 2),
            0
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 1, displayCount: 2),
            1
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 1),
            0
        )
    }

    func testDualMediaStreamsKeepCanvasInMediaStreamOrder() throws {
        let displayOne = AppleCanvas(width: 2560, height: 1440, tileCount: 4)
        let displayTwo = AppleCanvas(width: 1920, height: 1200, tileCount: 4)

        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 0,
                from: [displayOne, displayTwo]
            ),
            displayOne
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 1,
                from: [displayOne, displayTwo]
            ),
            displayTwo
        )
    }

}
