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
            sessionActivator: makeSessionActivator(
                authenticator: authenticator,
                connectionStore: connections,
                controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes)
            ),
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
        let connections = ConnectionStore(defaults: defaults)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(result: .success(session)),
                connectionStore: connections,
                preferences: preferences,
                controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes)
            ),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
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
        let connections = ConnectionStore(defaults: defaults)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(result: .success(session)),
                connectionStore: connections
            ),
            credentialStore: credentials,
            connectionStore: connections,
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
        let authenticator = MockAuthenticator(result: .success(try makeSession(endpoint: endpoint)))
        let connections = ConnectionStore(defaults: defaults)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: authenticator,
                connectionStore: connections
            ),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
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
        let connections = ConnectionStore(defaults: defaults)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(
                    result: .failure(AppleRSA1Error.authenticationRejected(1))
                ),
                connectionStore: connections
            ),
            credentialStore: credentials,
            connectionStore: connections,
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
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(result: .success(session)),
                connectionStore: connections,
                controlChannelNegotiator: MockControlChannelNegotiator(recorder: displaySizes)
            ),
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
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(result: .success(session)),
                connectionStore: connections,
                mediaNegotiator: MockMediaNegotiator(
                    pendingMessages: [dualDisplayLayoutMessage()]
                )
            ),
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
            sessionActivator: makeSessionActivator(
                authenticator: authenticator,
                connectionStore: connections
            ),
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
        let connections = ConnectionStore(defaults: defaults)
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: MockAuthenticator(result: .success(session)),
                connectionStore: connections
            ),
            credentialStore: FailingCredentialStore(),
            connectionStore: connections,
            sessionManager: sessions
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: true)
        try await waitUntil { coordinator.state == .authenticated }

        XCTAssertTrue(sessions.session(for: endpoint) === session)
    }

    func testPrefillsUsernameAndConnectsStandardMode() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ControlledAuthenticationTransport()
        let connections = ConnectionStore(defaults: defaults)
        connections.record(endpoint)
        let connection = try XCTUnwrap(connections.connection(for: endpoint))
        try connections.update(
            connection,
            name: connection.name,
            endpoint: endpoint,
            preferredUsername: "editor",
            sharingType: .standard,
            standardQuality: .balanced,
            virtualDisplayCount: .one
        )
        connections.clearRecentConnections()
        let authenticator = MockAuthenticator(
            result: .success(try makeSession(
                endpoint: endpoint,
                sharingType: .standard,
                transport: transport,
                width: 2,
                height: 1
            ))
        )
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: authenticator,
                connectionStore: connections
            ),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            sessionManager: SessionManager()
        )

        XCTAssertEqual(coordinator.preferredUsername(), "editor")
        coordinator.signIn(username: "editor", password: "password", rememberPassword: false)

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coordinator.state, .authenticating)
        transport.append(Data([
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 2, 0, 1,
            0, 0, 0, 0,
        ]) + Data(repeating: 0x7f, count: 2 * 4))
        try await waitUntil { coordinator.state == .authenticated }
        XCTAssertEqual(authenticator.requestedSharingType, .standard)
        XCTAssertEqual(connections.recentConnections.first?.standardQuality, .balanced)
    }

    func testCancellationClosesAuthenticatedSessionBeforeInstallation() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = CancellationRecordingTransport()
        let session = try makeSession(
            endpoint: endpoint,
            sharingType: .standard,
            transport: transport
        )
        let connections = ConnectionStore(defaults: defaults)
        connections.record(endpoint)
        let connection = try XCTUnwrap(connections.connection(for: endpoint))
        try connections.update(
            connection,
            name: connection.name,
            endpoint: endpoint,
            preferredUsername: "",
            sharingType: .standard,
            virtualDisplayCount: .one
        )
        let authenticator = SuspendingAuthenticator()
        let sessions = SessionManager()
        let coordinator = AuthenticationCoordinator(
            endpoint: endpoint,
            sessionActivator: makeSessionActivator(
                authenticator: authenticator,
                connectionStore: connections
            ),
            credentialStore: MockCredentialStore(),
            connectionStore: connections,
            sessionManager: sessions
        )

        coordinator.signIn(username: "user", password: "password", rememberPassword: false)
        try await waitUntil { authenticator.isWaiting }
        coordinator.cancel()
        authenticator.resume(returning: session)
        try await waitUntil { transport.cancelCount == 1 }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(sessions.session(for: endpoint))
    }

    private func makeSessionActivator(
        authenticator: any RFBAuthenticating,
        connectionStore: ConnectionStore,
        preferences: SessionFeaturePreferences? = nil,
        controlChannelNegotiator: any AppleControlChannelNegotiating = MockControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = MockMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = MockVideoStreamStarter()
    ) -> SessionActivation {
        SessionActivation(
            authenticator: authenticator,
            controlChannelNegotiator: controlChannelNegotiator,
            mediaNegotiator: mediaNegotiator,
            videoStreamStarter: videoStreamStarter,
            connectionStore: connectionStore,
            sessionFeaturePreferences: preferences
                ?? SessionFeaturePreferences(defaults: defaults)
        )
    }

    private func makeSession(
        endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType = .highPerformance,
        transport: (any RFBTransport)? = nil,
        width: UInt16 = 1920,
        height: UInt16 = 1080
    ) throws -> RFBAuthenticatedSession {
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        return RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            sharingType: sharingType,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: width,
                height: height,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport ?? NWConnectionTransport(remoteAddress: remoteAddress)
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
    private let lock = NSLock()
    private var sharingType: ScreenSharingType?

    init(result: Result<RFBAuthenticatedSession, Error>) {
        self.result = result
    }

    var requestedSharingType: ScreenSharingType? {
        lock.withLock { sharingType }
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        lock.withLock { self.sharingType = sharingType }
        return try result.get()
    }
}

private final class SuspendingAuthenticator: RFBAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RFBAuthenticatedSession, Error>?

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func resume(returning session: RFBAuthenticatedSession) {
        let continuation = lock.withLock { () -> CheckedContinuation<RFBAuthenticatedSession, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: session)
    }
}

private final class CancellationRecordingTransport: RFBTransport, @unchecked Sendable {
    private struct PendingRead {
        let length: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var cancellations = 0
    private var receiveData = Data()
    private var pendingRead: PendingRead?

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    func start(timeout: Duration) async throws { }
    func send(_ data: Data) async throws { }
    func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Data, Error>? in
                guard receiveData.count >= length else {
                    precondition(pendingRead == nil)
                    pendingRead = PendingRead(length: length, continuation: continuation)
                    return nil
                }
                let result = Data(receiveData.prefix(length))
                receiveData.removeFirst(length)
                return .success(result)
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func append(_ data: Data) {
        let delivery = lock.withLock { () -> (PendingRead, Data)? in
            receiveData.append(data)
            guard let pendingRead, receiveData.count >= pendingRead.length else { return nil }
            let result = Data(receiveData.prefix(pendingRead.length))
            receiveData.removeFirst(pendingRead.length)
            self.pendingRead = nil
            return (pendingRead, result)
        }
        if let (pendingRead, result) = delivery {
            pendingRead.continuation.resume(returning: result)
        }
    }

    func cancel() {
        let pendingRead = lock.withLock { () -> PendingRead? in
            cancellations += 1
            defer { self.pendingRead = nil }
            return self.pendingRead
        }
        pendingRead?.continuation.resume(throwing: RFBNetworkError.connectionClosed)
    }
}

private typealias ControlledAuthenticationTransport = CancellationRecordingTransport

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
        session.install(recordLayer: layer)
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
        return result
    }
}

private struct MockVideoStreamStarter: AppleVideoStreamStarting {
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult
    ) throws { }
}
