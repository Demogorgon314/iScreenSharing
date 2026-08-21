import XCTest
@testable import iShareScreen

final class AppleMediaNegotiatorTests: XCTestCase {
    func testFramebufferStartupArmsAllScreensBeforeMediaOffer() throws {
        XCTAssertEqual(
            try AppleMediaNegotiator.framebufferStartupMessages(),
            [
                try AppleRFBMessages.setEncodings(),
                AppleRFBMessages.framebufferUpdateRequest(),
                AppleRFBMessages.autoFramebufferUpdate(),
            ]
        )
    }

    func testMultipleDisplayStartupUsesSameFramebufferArming() throws {
        XCTAssertEqual(
            try AppleMediaNegotiator.framebufferStartupMessages(displayCount: 2),
            [
                try AppleRFBMessages.setEncodings(),
                AppleRFBMessages.framebufferUpdateRequest(),
                AppleRFBMessages.autoFramebufferUpdate(),
            ]
        )
    }

    func testDualMediaStreamsMapToOppositeVirtualDisplayOrder() {
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 2),
            1
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 1, displayCount: 2),
            0
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 1),
            0
        )
    }

    func testDualMediaStreamsUseCanvasForTheirMappedDisplay() throws {
        let displayOne = AppleCanvas(width: 2560, height: 1440, tileCount: 4)
        let displayTwo = AppleCanvas(width: 1920, height: 1200, tileCount: 4)

        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 0,
                from: [displayOne, displayTwo]
            ),
            displayTwo
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 1,
                from: [displayOne, displayTwo]
            ),
            displayOne
        )
    }

}
