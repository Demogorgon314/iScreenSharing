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

}
