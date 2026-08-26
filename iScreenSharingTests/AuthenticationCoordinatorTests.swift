import XCTest
@testable import iScreenSharing

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
        let session = try makeSession(endpoint: endpoint)
        let authenticator = MockAuthenticator(result: .success(session))
        let credentials = MockCredentialStore()
        let connections = ConnectionStore(defaults: defaults)
        let sessions = SessionManager()
        let viewportStore = SessionViewportStore(defaults: defaults)
        viewportStore.save(CGSize(width: 1280, height: 720), for: endpoint)
        let displaySizes = DisplaySizeRecorder()
        var authenticatedEndpoint: ConnectionEndpoint?
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: authenticator,
            controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: credentials,
            connectionStore: connections,
            viewportStore: viewportStore,
            sessionManager: sessions,
            onAuthenticated: { authenticatedEndpoint = $0 }
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: true)
        try await waitUntil { coordinator.state == .authenticated && credentials.saved != nil }

        XCTAssertTrue(sessions.session(for: endpoint) === session)
        XCTAssertEqual(connections.connections.first?.endpoint, endpoint)
        XCTAssertEqual(connections.connections.first?.preferredUsername, "user")
        XCTAssertEqual(authenticatedEndpoint, endpoint)
        let initialDisplaySize = await displaySizes.first()
        XCTAssertEqual(initialDisplaySize, AppleDynamicResolutionSize(width: 1280, height: 720))
        XCTAssertEqual(
            credentials.saved,
            try ScreenSharingCredentials(username: "user", password: "password")
        )
    }

    func testSuccessfulSignInRestoresSessionFeaturePreferences() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = try makeSession(endpoint: endpoint)
        let preferences = SessionFeaturePreferences(defaults: defaults)
        preferences.setSharesKeyboardInputSource(true)
        preferences.setUsesDynamicResolution(false)
        let displaySizes = DisplaySizeRecorder()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(session)),
            controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: MockCredentialStore(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: preferences,
            sessionManager: SessionManager()
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: false)
        try await waitUntil { coordinator.state == .authenticated }

        XCTAssertTrue(session.keyboardInputSourceService?.isSharingEnabled == true)
        XCTAssertFalse(session.dynamicResolutionModel?.isEnabled == true)
        let initialDisplaySize = await displaySizes.first()
        XCTAssertEqual(
            initialDisplaySize,
            AppleDynamicResolutionSize(width: 1_920, height: 1_080)
        )
    }

    func testAutomaticallySignsInWithSavedCredentials() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = try makeSession(endpoint: endpoint)
        let credentials = MockCredentialStore()
        let savedCredentials = try ScreenSharingCredentials(
            username: "saved-user",
            password: "saved-password"
        )
        try credentials.save(savedCredentials, for: endpoint)
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(session)),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: credentials,
            connectionStore: ConnectionStore(defaults: defaults),
            sessionManager: sessions
        )

        let restoredCredentials = await coordinator.signInWithSavedCredentials()
        try await waitUntil { coordinator.state == .authenticated }

        XCTAssertEqual(restoredCredentials, savedCredentials)
        XCTAssertTrue(sessions.session(for: endpoint) === session)
    }

    func testAutomaticSignInWithoutSavedCredentialsKeepsCoordinatorIdle() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(try makeSession(endpoint: endpoint))),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: MockCredentialStore(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionManager: sessions
        )

        let restoredCredentials = await coordinator.signInWithSavedCredentials()

        XCTAssertNil(restoredCredentials)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(sessions.session(for: endpoint))
    }

    func testRejectedAutomaticSignInKeepsSavedCredentialsForManualRetry() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let credentials = MockCredentialStore()
        let savedCredentials = try ScreenSharingCredentials(
            username: "saved-user",
            password: "stale-password"
        )
        try credentials.save(savedCredentials, for: endpoint)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(
                result: .failure(AppleRSA1Error.authenticationRejected(1))
            ),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: credentials,
            connectionStore: ConnectionStore(defaults: defaults),
            sessionManager: SessionManager()
        )

        let restoredCredentials = await coordinator.signInWithSavedCredentials()
        try await waitUntil {
            if case .failed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(restoredCredentials, savedCredentials)
        guard case .failed = coordinator.state else {
            return XCTFail("Expected saved-credential authentication to fail")
        }
    }

    func testRestoresEachVirtualDisplaySizeDuringAuthentication() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = try makeSession(endpoint: endpoint)
        let connections = ConnectionStore(defaults: defaults)
        connections.record(endpoint)
        let saved = try XCTUnwrap(connections.connection(for: endpoint))
        try connections.update(
            saved,
            name: saved.name,
            endpoint: endpoint,
            preferredUsername: "",
            sharingType: .highPerformance,
            virtualDisplayCount: .two
        )
        let viewportStore = SessionViewportStore(defaults: defaults)
        viewportStore.save(CGSize(width: 1200, height: 800), for: endpoint, displayIndex: 0)
        viewportStore.save(CGSize(width: 900, height: 700), for: endpoint, displayIndex: 1)
        let displaySizes = DisplaySizeRecorder()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(session)),
            controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            viewportStore: viewportStore,
            sessionManager: SessionManager()
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: false)
        try await waitUntil { coordinator.state == .authenticated }

        let request = await displaySizes.firstRequest()
        XCTAssertEqual(request, [
            AppleDynamicResolutionSize(width: 1200, height: 800),
            AppleDynamicResolutionSize(width: 900, height: 700),
        ])
        XCTAssertNotNil(session.dynamicResolutionModel)
    }

    func testSeedsDualDisplayLayoutBeforePublishingSession() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = try makeSession(endpoint: endpoint)
        let connections = ConnectionStore(defaults: defaults)
        connections.record(endpoint)
        let saved = try XCTUnwrap(connections.connection(for: endpoint))
        try connections.update(
            saved,
            name: saved.name,
            endpoint: endpoint,
            preferredUsername: "",
            sharingType: .highPerformance,
            virtualDisplayCount: .two
        )
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(session)),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(pendingMessages: [dualDisplayLayoutMessage()]),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            sessionManager: SessionManager()
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: false)
        try await waitUntil { coordinator.state == .authenticated }

        let layoutModel = try XCTUnwrap(session.displayLayoutModel)
        XCTAssertEqual(layoutModel.displayCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(layoutModel.inputMapping(for: 1)).backingFrame,
            CGRect(x: 2160, y: 0, width: 2160, height: 1752)
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
            videoStreamStarter: MockVideoStreamStarter(),
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

    func testCredentialPersistenceFailureDoesNotFailConnectedSession() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = try makeSession(endpoint: endpoint)
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(session)),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: FailingCredentialStore(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionManager: sessions
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: true)
        try await waitUntil { coordinator.state == .authenticated }

        XCTAssertTrue(sessions.session(for: endpoint) === session)
    }

    func testPrefillsUsernameAndRejectsUnsupportedStandardMode() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let connections = ConnectionStore(defaults: defaults)
        connections.record(endpoint)
        let connection = try XCTUnwrap(connections.connection(for: endpoint))
        try connections.update(
            connection,
            name: connection.name,
            endpoint: endpoint,
            preferredUsername: "editor",
            sharingType: .standard,
            virtualDisplayCount: .one
        )
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            authenticator: MockAuthenticator(result: .success(try makeSession(endpoint: endpoint))),
            controlChannelNegotiator: MockControlChannelNegotiator(),
            mediaNegotiator: MockMediaNegotiator(),
            videoStreamStarter: MockVideoStreamStarter(),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            sessionManager: SessionManager()
        )

        XCTAssertEqual(coordinator.preferredUsername(), "editor")
        coordinator.signIn(username: "editor", password: "password", rememberPassword: false)

        XCTAssertEqual(
            coordinator.state,
            .failed(AuthenticationCoordinatorError.standardModeUnavailable.localizedDescription)
        )
    }

    private func makeSession(endpoint: ConnectionEndpoint) throws -> RFBAuthenticatedSession {
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        return RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            serverVersion: RFBVersion(major: 3, minor: 889),
            securityTypes: [.appleRSA],
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: NWConnectionTransport(remoteAddress: remoteAddress)
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

    private func dualDisplayLayoutMessage() -> Data {
        var payload = Data(repeating: 0, count: 132)
        payload.writeUInt16BE(5, at: 0)
        payload.writeUInt16BE(2160, at: 2)
        payload.writeUInt16BE(876, at: 4)
        payload.writeUInt16BE(4320, at: 6)
        payload.writeUInt16BE(1752, at: 8)
        payload.writeUInt16BE(2, at: 18)
        for (index, x) in [0, 2160].enumerated() {
            let offset = 20 + index * 56
            payload.writeUInt32BE(UInt32(100 + index), at: offset + 16)
            payload.writeUInt16BE(UInt16(x / 2), at: offset + 22)
            payload.writeUInt16BE(UInt16((x + 2160) / 2), at: offset + 26)
            payload.writeUInt16BE(UInt16(x), at: offset + 30)
            payload.writeUInt16BE(UInt16(x + 2160), at: offset + 34)
            payload.writeUInt16BE(876, at: offset + 24)
            payload.writeUInt16BE(1752, at: offset + 32)
        }
        var message = Data([0, 0, 0, 1])
        message.append(Data(repeating: 0, count: 8))
        message.appendInt32BE(0x451)
        message.appendUInt16BE(UInt16(payload.count))
        message.append(payload)
        return message
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
    private let lock = NSLock()
    private var stored: ScreenSharingCredentials?

    var saved: ScreenSharingCredentials? {
        lock.withLock { stored }
    }

    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials? {
        lock.withLock { stored }
    }

    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws {
        lock.withLock { stored = credentials }
    }

    func delete(for endpoint: ConnectionEndpoint) throws {
        lock.withLock { stored = nil }
    }
}

private struct FailingCredentialStore: CredentialStoring {
    private struct PersistenceError: Error { }

    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials? { nil }
    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws {
        throw PersistenceError()
    }
    func delete(for endpoint: ConnectionEndpoint) throws { throw PersistenceError() }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private struct MockControlChannelNegotiator: AppleControlChannelNegotiating {
    let recorder: DisplaySizeRecorder?

    init(recorder: DisplaySizeRecorder? = nil) {
        self.recorder = recorder
    }

    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer {
        await recorder?.append(displaySizes)
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

private actor DisplaySizeRecorder {
    private var requests = [[AppleDynamicResolutionSize]]()

    func append(_ sizes: [AppleDynamicResolutionSize]) { requests.append(sizes) }
    func first() -> AppleDynamicResolutionSize? { requests.first?.first }
    func firstRequest() -> [AppleDynamicResolutionSize]? { requests.first }
}

private struct MockMediaNegotiator: AppleMediaNegotiating {
    let pendingMessages: [Data]

    init(pendingMessages: [Data] = []) {
        self.pendingMessages = pendingMessages
    }

    func negotiate(
        _ session: RFBAuthenticatedSession,
        displayCount: Int
    ) async throws -> AppleMediaNegotiationResult {
        let keys = AppleMediaKeys(
            audioViewer: Data(repeating: 1, count: 46),
            audioServer: Data(repeating: 2, count: 46),
            videoViewer: Data(repeating: 3, count: 46),
            videoServer: Data(repeating: 4, count: 46)
        )
        let result = AppleMediaNegotiationResult(
            keys: keys,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4),
            videoSynchronizationSource: 0x1122_3344,
            configuration: Data([0x1c]),
            pendingMessages: pendingMessages
        )
        session.install(mediaNegotiation: result)
        return result
    }
}

private struct MockVideoStreamStarter: AppleVideoStreamStarting {
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult
    ) throws { }
}
