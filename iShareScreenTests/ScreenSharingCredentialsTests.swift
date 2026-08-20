import XCTest
@testable import iShareScreen

final class ScreenSharingCredentialsTests: XCTestCase {
    func testNormalizesUsernameWithoutChangingPassword() throws {
        let credentials = try ScreenSharingCredentials(
            username: "  deepdream \n",
            password: " spaces matter "
        )

        XCTAssertEqual(credentials.username, "deepdream")
        XCTAssertEqual(credentials.password, " spaces matter ")
    }

    func testRejectsMissingOrOversizedValues() {
        XCTAssertThrowsError(try ScreenSharingCredentials(username: "", password: "secret"))
        XCTAssertThrowsError(try ScreenSharingCredentials(username: "user", password: ""))
        XCTAssertThrowsError(
            try ScreenSharingCredentials(username: String(repeating: "a", count: 64), password: "secret")
        )
        XCTAssertThrowsError(
            try ScreenSharingCredentials(username: "user", password: String(repeating: "a", count: 64))
        )
    }
}

