import XCTest
@testable import iShareScreen

@MainActor
final class AuthenticationCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AuthenticationCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuccessfulSignInInstallsSessionRecordsConnectionAndSavesCredentials() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = makeSession(endpoint: endpoint)
        let authenticator = MockAuthenticator(result: .success(session))
        let credentials = MockCredentialStore()
        let connections = ConnectionStore(defaults: defaults)
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: authenticator,
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            credentialStore: credentials,
            connectionStore: connections,
            sessionManager: sessions
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: true)
        try await waitUntil { coordinator.state == .authenticated }

        XCTAssertTrue(sessions.session(for: endpoint) === session)
        XCTAssertEqual(connections.connections.first?.endpoint, endpoint)
        XCTAssertEqual(
            credentials.saved,
            try ScreenSharingCredentials(username: "user", password: "password")
        )
    }

    func testRejectedSignInSurfacesErrorWithoutRecordingConnection() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let authenticator = MockAuthenticator(
            result: .failure(AppleRSA1Error.authenticationRejected(1))
        )
        let connections = ConnectionStore(defaults: defaults)
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: authenticator,
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            sessionManager: sessions
        )

        coordinator.signIn(username: "user", password: "wrong", rememberPassword: false)
        try await waitUntil {
            if case .failed = coordinator.state { return true }
            return false
        }

        XCTAssertTrue(connections.connections.isEmpty)
        XCTAssertNil(sessions.session(for: endpoint))
    }

    private func makeSession(endpoint: ConnectionEndpoint) -> RFBAuthenticatedSession {
        RFBAuthenticatedSession(
            endpoint: endpoint,
            serverVersion: RFBVersion(major: 3, minor: 889),
            securityTypes: [.appleRSA],
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: NWConnectionTransport(endpoint: endpoint)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class MockAuthenticator: RFBAuthenticating, @unchecked Sendable {
    let result: Result<RFBAuthenticatedSession, Error>

    init(result: Result<RFBAuthenticatedSession, Error>) {
        self.result = result
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials
    ) async throws -> RFBAuthenticatedSession {
        try result.get()
    }
}

private final class MockCredentialStore: CredentialStoring, @unchecked Sendable {
    private(set) var saved: ScreenSharingCredentials?

    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials? {
        saved
    }

    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws {
        saved = credentials
    }

    func delete(for endpoint: ConnectionEndpoint) throws {
        saved = nil
    }
}

private struct MockControlChannelNegotiator: AppleControlChannelNegotiating {
    func enableEncryption(
        for session: RFBAuthenticatedSession
    ) async throws -> AppleEncryptedRecordLayer {
        let layer = AppleEncryptedRecordLayer(
            keys: try AppleRecordKeys(
                key: Data(repeating: 0x11, count: 16),
                initializationVector: Data(repeating: 0x22, count: 16)
            )
        )
        session.install(recordLayer: layer, generation: 1)
        return layer
    }
}

private struct MockMediaNegotiator: AppleMediaNegotiating {
    func negotiate(_ session: RFBAuthenticatedSession) async throws -> AppleMediaNegotiationResult {
        let keys = AppleMediaKeys(
            audioViewer: Data(repeating: 1, count: 46),
            audioServer: Data(repeating: 2, count: 46),
            videoViewer: Data(repeating: 3, count: 46),
            videoServer: Data(repeating: 4, count: 46)
        )
        let result = AppleMediaNegotiationResult(
            keys: keys,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            pendingMessages: []
        )
        session.install(mediaNegotiation: result)
        return result
    }
}
