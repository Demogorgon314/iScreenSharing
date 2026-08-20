import XCTest
@testable import iShareScreen

final class RFBAuthenticationIntegrationTests: XCTestCase {
    func testAuthenticatesAgainstConfiguredMac() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ISHARESCREEN_TEST_HOST"],
              let username = environment["ISHARESCREEN_TEST_USERNAME"],
              let password = environment["ISHARESCREEN_TEST_PASSWORD"] else {
            throw XCTSkip("Set ISHARESCREEN_TEST_HOST, _USERNAME, and _PASSWORD to run the LAN integration test.")
        }

        let session = try await RFBAuthenticationService().connect(
            to: ConnectionEndpoint(host),
            credentials: ScreenSharingCredentials(username: username, password: password)
        )
        defer { session.close() }

        XCTAssertEqual(session.serverVersion, RFBVersion(major: 3, minor: 889))
        XCTAssertEqual(session.masterKey.count, 16)
        XCTAssertTrue(session.securityTypes.contains(.appleRSA))
        XCTAssertGreaterThan(session.serverInfo.width, 0)
        XCTAssertGreaterThan(session.serverInfo.height, 0)

        let recordLayer = try await AppleControlChannelNegotiator().enableEncryption(for: session)
        XCTAssertEqual(recordLayer.contentKey.count, 16)
        XCTAssertEqual(session.recordLayer?.contentKey, recordLayer.contentKey)
        XCTAssertGreaterThanOrEqual(session.rekeyGeneration ?? 0, 1)

        let media = try await AppleMediaNegotiator().negotiate(session)
        XCTAssertTrue(media.canvas.isUsable)
        XCTAssertGreaterThan(media.canvas.width, 0)
        XCTAssertGreaterThan(media.canvas.height, 0)
        XCTAssertGreaterThan(media.canvas.tileCount, 0)
        XCTAssertEqual(session.mediaNegotiation, media)
    }
}
