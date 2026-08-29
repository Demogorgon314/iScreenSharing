import XCTest
@testable import iScreenSharing

@MainActor
final class SessionActivationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SessionActivationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testHighPerformanceActivationReturnsSessionWithRequiredResources() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let authenticator = ActivationFixedAuthenticator(session: session)
        let displaySizes = ActivationDisplaySizeRecorder()
        let activation = SessionActivation(
            authenticator: authenticator,
            controlChannelNegotiator: ActivationControlChannelNegotiator(
                displaySizes: displaySizes
            ),
            mediaNegotiator: ActivationMediaNegotiator(),
            videoStreamStarter: ActivationVideoStreamStarter(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )
        let requestedSizes = [
            AppleDynamicResolutionSize(width: 1_280, height: 720),
            AppleDynamicResolutionSize(width: 1_024, height: 768),
        ]

        let activated = try await activation.activate(
            endpoint: endpoint,
            credentials: try ScreenSharingCredentials(
                username: "user",
                password: "password"
            ),
            configuration: SessionActivationConfiguration(
                sharingType: .highPerformance,
                standardQuality: .high,
                virtualDisplayCount: .two,
                requestedDisplaySizes: requestedSizes
            )
        )

        XCTAssertTrue(activated === session)
        XCTAssertEqual(authenticator.requestedSharingType, .highPerformance)
        let recordedDisplaySizes = await displaySizes.value
        XCTAssertEqual(recordedDisplaySizes, requestedSizes)
        XCTAssertNotNil(session.videoStream)
        XCTAssertNotNil(session.inputController)
        XCTAssertNotNil(session.controlMessageService)
        XCTAssertNotNil(session.clipboardService)
        XCTAssertNotNil(session.cursorStore)
        XCTAssertEqual(session.displayLayoutModel?.displayCount, 2)
        XCTAssertNotNil(session.dynamicResolutionModel)
        XCTAssertNotNil(session.remoteSystemCapabilities)
        XCTAssertNotNil(session.keyboardInputSourceService)
        XCTAssertNotNil(session.controlState)
        session.close()
    }

    func testStandardActivationReturnsOnlyAfterFirstCompleteFramebuffer() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(
            endpoint: endpoint,
            sharingType: .standard,
            transport: transport,
            width: 2,
            height: 1
        )
        let activation = makeActivation(
            authenticator: ActivationFixedAuthenticator(session: session)
        )
        let completion = ActivationCompletionRecorder()
        let task = Task {
            let session = try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: standardConfiguration
            )
            await completion.markCompleted()
            return session
        }

        try await waitUntil { transport.hasPendingRead }
        let completedBeforeFramebuffer = await completion.isCompleted
        XCTAssertFalse(completedBeforeFramebuffer)

        transport.append(initialFramebufferMessage(width: 2, height: 1))
        let activated = try await task.value

        XCTAssertTrue(activated === session)
        XCTAssertEqual(session.videoStream?.state, .streaming)
        let completedAfterFramebuffer = await completion.isCompleted
        XCTAssertTrue(completedAfterFramebuffer)
        session.close()
    }

    func testStandardActivationCancellationWhileWaitingForFirstFrameClosesSession() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(
            endpoint: endpoint,
            sharingType: .standard,
            transport: transport,
            width: 2,
            height: 1
        )
        let activation = makeActivation(
            authenticator: ActivationFixedAuthenticator(session: session)
        )
        let task = Task {
            try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: standardConfiguration
            )
        }
        try await waitUntil { transport.hasPendingRead }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected Standard activation to be cancelled")
        } catch is CancellationError {
        }
        try await waitUntil { transport.cancelCount == 1 }
    }

    func testActivationFailureClosesAuthenticatedSession() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let activation = SessionActivation(
            authenticator: ActivationFixedAuthenticator(session: session),
            controlChannelNegotiator: ActivationFailingControlChannelNegotiator(),
            mediaNegotiator: ActivationMediaNegotiator(),
            videoStreamStarter: ActivationVideoStreamStarter(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )

        do {
            _ = try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: highPerformanceConfiguration
            )
            XCTFail("Expected activation to fail")
        } catch let error as ActivationTestError {
            XCTAssertEqual(error, .expected)
        }

        try await waitUntil { transport.cancelCount == 1 }
    }

    func testCancellationAfterAuthenticationClosesSessionWithoutStartingMode() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let authenticator = ActivationSuspendingAuthenticator()
        let displaySizes = ActivationDisplaySizeRecorder()
        let activation = SessionActivation(
            authenticator: authenticator,
            controlChannelNegotiator: ActivationControlChannelNegotiator(
                displaySizes: displaySizes
            ),
            mediaNegotiator: ActivationMediaNegotiator(),
            videoStreamStarter: ActivationVideoStreamStarter(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )
        let task = Task {
            try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: highPerformanceConfiguration
            )
        }
        try await waitUntil { authenticator.isWaiting }

        task.cancel()
        authenticator.resume(returning: session)

        do {
            _ = try await task.value
            XCTFail("Expected activation to be cancelled")
        } catch is CancellationError {
        }
        try await waitUntil { transport.cancelCount == 1 }
        let recordedDisplaySizes = await displaySizes.value
        XCTAssertNil(recordedDisplaySizes)
    }

    func testSharingTypeMismatchClosesSessionBeforeModeActivation() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let displaySizes = ActivationDisplaySizeRecorder()
        let activation = SessionActivation(
            authenticator: ActivationFixedAuthenticator(session: session),
            controlChannelNegotiator: ActivationControlChannelNegotiator(
                displaySizes: displaySizes
            ),
            mediaNegotiator: ActivationMediaNegotiator(),
            videoStreamStarter: ActivationVideoStreamStarter(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )

        do {
            _ = try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: SessionActivationConfiguration(
                    sharingType: .standard,
                    standardQuality: .high,
                    virtualDisplayCount: .one,
                    requestedDisplaySizes: []
                )
            )
            XCTFail("Expected activation to reject the mismatched mode")
        } catch let error as SessionActivationError {
            XCTAssertEqual(
                error,
                .sharingTypeMismatch(expected: .standard, actual: .highPerformance)
            )
        }

        try await waitUntil { transport.cancelCount == 1 }
        let recordedDisplaySizes = await displaySizes.value
        XCTAssertNil(recordedDisplaySizes)
    }

    func testInvalidHighPerformanceDisplayConfigurationFailsBeforeAuthentication() async throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let transport = ActivationRecordingTransport()
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let authenticator = ActivationFixedAuthenticator(session: session)
        let activation = makeActivation(authenticator: authenticator)

        do {
            _ = try await activation.activate(
                endpoint: endpoint,
                credentials: try ScreenSharingCredentials(
                    username: "user",
                    password: "password"
                ),
                configuration: SessionActivationConfiguration(
                    sharingType: .highPerformance,
                    standardQuality: .high,
                    virtualDisplayCount: .two,
                    requestedDisplaySizes: [
                        AppleDynamicResolutionSize(width: 1_440, height: 900),
                    ]
                )
            )
            XCTFail("Expected invalid display configuration to fail")
        } catch let error as SessionActivationError {
            XCTAssertEqual(
                error,
                .invalidDisplayConfiguration(expectedCount: 2, actualCount: 1)
            )
        }

        XCTAssertNil(authenticator.requestedSharingType)
        XCTAssertEqual(transport.cancelCount, 0)
    }

    private var highPerformanceConfiguration: SessionActivationConfiguration {
        SessionActivationConfiguration(
            sharingType: .highPerformance,
            standardQuality: .high,
            virtualDisplayCount: .one,
            requestedDisplaySizes: [AppleDynamicResolutionSize(width: 1_440, height: 900)]
        )
    }

    private var standardConfiguration: SessionActivationConfiguration {
        SessionActivationConfiguration(
            sharingType: .standard,
            standardQuality: .high,
            virtualDisplayCount: .one,
            requestedDisplaySizes: []
        )
    }

    private func makeActivation(
        authenticator: any RFBAuthenticating
    ) -> SessionActivation {
        SessionActivation(
            authenticator: authenticator,
            controlChannelNegotiator: ActivationFailingControlChannelNegotiator(),
            mediaNegotiator: ActivationMediaNegotiator(),
            videoStreamStarter: ActivationVideoStreamStarter(),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )
    }

    private func initialFramebufferMessage(width: Int, height: Int) -> Data {
        Data([
            0, 0, 0, 1,
            0, 0, 0, 0,
            0, UInt8(width), 0, UInt8(height),
            0, 0, 0, 0,
        ]) + Data(repeating: 0x7f, count: width * height * 4)
    }

    private func makeSession(
        endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType = .highPerformance,
        transport: any RFBTransport,
        width: UInt16 = 1_920,
        height: UInt16 = 1_080
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
            transport: transport
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for activation state")
                return
            }
            await Task.yield()
        }
    }
}

private enum ActivationTestError: Error, Equatable {
    case expected
}

private final class ActivationFixedAuthenticator: RFBAuthenticating, @unchecked Sendable {
    let session: RFBAuthenticatedSession
    private let lock = NSLock()
    private var sharingType: ScreenSharingType?

    init(session: RFBAuthenticatedSession) {
        self.session = session
    }

    var requestedSharingType: ScreenSharingType? {
        lock.withActivationLock { sharingType }
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        lock.withActivationLock { self.sharingType = sharingType }
        return session
    }
}

private final class ActivationSuspendingAuthenticator: RFBAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RFBAuthenticatedSession, Error>?

    var isWaiting: Bool {
        lock.withActivationLock { continuation != nil }
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        try await withCheckedThrowingContinuation { continuation in
            lock.withActivationLock { self.continuation = continuation }
        }
    }

    func resume(returning session: RFBAuthenticatedSession) {
        let continuation = lock.withActivationLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: session)
    }
}

private struct ActivationControlChannelNegotiator: AppleControlChannelNegotiating {
    let displaySizes: ActivationDisplaySizeRecorder

    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer {
        await self.displaySizes.record(displaySizes)
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

private struct ActivationFailingControlChannelNegotiator: AppleControlChannelNegotiating {
    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer {
        throw ActivationTestError.expected
    }
}

private actor ActivationDisplaySizeRecorder {
    private(set) var value: [AppleDynamicResolutionSize]?

    func record(_ value: [AppleDynamicResolutionSize]) {
        self.value = value
    }
}

private actor ActivationCompletionRecorder {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private struct ActivationMediaNegotiator: AppleMediaNegotiating {
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
        return AppleMediaNegotiationResult(
            keys: keys,
            canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            videoSynchronizationSource: 0x1122_3344,
            configuration: Data([0x1c]),
            pendingMessages: []
        )
    }
}

private struct ActivationVideoStreamStarter: AppleVideoStreamStarting {
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult
    ) throws {
        let stream = ActivationVideoStream(canvas: negotiation.canvas)
        session.install(videoStream: stream)
        stream.start()
    }
}

private final class ActivationVideoStream: SessionVideoStream, @unchecked Sendable {
    init(canvas: AppleCanvas) {
        super.init(canvas: canvas, displayIndex: 0, tileCount: canvas.tileCount)
    }

    override func start() {
        state = .streaming
    }

    override func close() {
        state = .stopped
    }
}

private final class ActivationRecordingTransport: RFBTransport, @unchecked Sendable {
    private struct PendingRead {
        let length: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var cancellations = 0
    private var receiveData = Data()
    private var pendingRead: PendingRead?

    var cancelCount: Int {
        lock.withActivationLock { cancellations }
    }

    var hasPendingRead: Bool {
        lock.withActivationLock { pendingRead != nil }
    }

    func start(timeout: Duration) async throws { }
    func send(_ data: Data) async throws { }
    func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withActivationLock { () -> Data? in
                guard receiveData.count >= length else {
                    precondition(pendingRead == nil)
                    pendingRead = PendingRead(length: length, continuation: continuation)
                    return nil
                }
                let result = Data(receiveData.prefix(length))
                receiveData.removeFirst(length)
                return result
            }
            if let result {
                continuation.resume(returning: result)
            }
        }
    }

    func append(_ data: Data) {
        let delivery = lock.withActivationLock { () -> (PendingRead, Data)? in
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
        let pendingRead = lock.withActivationLock { () -> PendingRead? in
            cancellations += 1
            defer { self.pendingRead = nil }
            return self.pendingRead
        }
        pendingRead?.continuation.resume(throwing: RFBNetworkError.connectionClosed)
    }
}

private extension NSLock {
    func withActivationLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
