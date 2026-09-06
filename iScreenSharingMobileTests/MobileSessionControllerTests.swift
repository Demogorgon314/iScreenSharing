import Combine
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileSessionControllerTests: XCTestCase {
    func testRestoredPresetIsUsedInInitialNegotiationWithoutViewport() async throws {
        let suite = "MobileSessionControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = try ConnectionEndpoint("studio-mac.local")
        MobileResolutionPreferences(defaults: defaults).save(.fullHD, for: endpoint)
        let address = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: endpoint.port)
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: address,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1440, height: 900,
                pixelFormat: Data(repeating: 0, count: 16), name: "Test Mac"
            ),
            transport: ResolutionTestTransport()
        )
        let negotiated = expectation(description: "Saved resolution sent in initial negotiation")
        let controller = MobileSessionController(
            endpoint: endpoint,
            authenticator: ResolutionTestAuthenticator(session: session),
            controlChannelNegotiator: ResolutionTestNegotiator { sizes in
                XCTAssertEqual(sizes, [.fixed1080p])
                negotiated.fulfill()
            },
            resolutionPreferences: MobileResolutionPreferences(defaults: defaults)
        )
        controller.connect(username: "viewer", password: "test")
        await fulfillment(of: [negotiated], timeout: 2)
        controller.disconnect()
        XCTAssertEqual(MobileResolutionPreferences(defaults: defaults).preset(for: endpoint), .fullHD)
    }

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

private struct ResolutionTestAuthenticator: RFBAuthenticating {
    let session: RFBAuthenticatedSession

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession { session }
}

private struct ResolutionTestNegotiator: AppleControlChannelNegotiating {
    let record: @Sendable ([AppleDynamicResolutionSize]) -> Void

    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer {
        record(displaySizes)
        throw TestError.unexpectedAuthentication
    }
}

private final class ResolutionTestTransport: RFBTransport, @unchecked Sendable {
    func start(timeout: Duration) async throws { throw TestError.unexpectedAuthentication }
    func send(_ data: Data) async throws { throw TestError.unexpectedAuthentication }
    func receiveExactly(_ length: Int) async throws -> Data { throw TestError.unexpectedAuthentication }
    func cancel() {}
}
