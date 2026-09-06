import Combine
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileSessionControllerTests: XCTestCase {
    func testRejectsMissingUsernameBeforeAuthentication() async throws {
        let endpoint = try ConnectionEndpoint(host: "studio-mac.local")
        let authenticator = RecordingAuthenticator()
        let controller = MobileSessionController(endpoint: endpoint, authenticator: authenticator)

        controller.connect(username: "   ", password: "secret")
        await waitUntilSettled(controller)

        XCTAssertEqual(
            controller.state,
            .failed("Enter the account name for the remote Mac.")
        )
        let connectCount = await authenticator.connectCount
        XCTAssertEqual(connectCount, 0)
    }

    func testDisconnectCancelsAuthentication() async throws {
        let endpoint = try ConnectionEndpoint(host: "studio-mac.local")
        let authenticator = RecordingAuthenticator(delay: .seconds(60))
        let controller = MobileSessionController(endpoint: endpoint, authenticator: authenticator)

        controller.connect(username: "viewer", password: "secret")
        await Task.yield()
        controller.disconnect()
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.session)
    }

    private func waitUntilSettled(_ controller: MobileSessionController) async {
        for _ in 0..<20 where controller.state == .connecting {
            await Task.yield()
        }
    }
}

private actor RecordingAuthenticator: RFBAuthenticating {
    private(set) var connectCount = 0
    private let delay: Duration?

    init(delay: Duration? = nil) {
        self.delay = delay
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        connectCount += 1
        if let delay { try await Task.sleep(for: delay) }
        throw TestError.unexpectedAuthentication
    }
}

private enum TestError: Error {
    case unexpectedAuthentication
}
