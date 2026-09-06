import Combine
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaKeys
import struct ScreenSharingProtocol.AppleMediaPorts
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileSessionControllerTests: XCTestCase {
    func testFitScreenFollowsLateViewportAndCoalescesRotationButFixedPresetDoesNot() async throws {
        let suite = "MobileSessionControllerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = try ConnectionEndpoint("test.local")
        let transport = try ViewportTransport()
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(width: 1440, height: 900, pixelFormat: Data(repeating: 0, count: 16), name: "Test"),
            transport: transport
        )
        let controller = MobileSessionController(
            endpoint: endpoint, authenticator: ResolutionTestAuthenticator(session: session),
            controlChannelNegotiator: ViewportNegotiator(), mediaNegotiator: ViewportNegotiator(),
            videoStreamStarter: ViewportVideoStarter(), resolutionPreferences: MobileResolutionPreferences(defaults: defaults)
        )
        defer { controller.disconnect() }
        let connected = expectation(description: "Connected without initial geometry")
        let connectionObserver = controller.$state.filter { $0 == .connected }.sink { _ in connected.fulfill() }
        defer { connectionObserver.cancel() }
        controller.connect(username: "viewer", password: "test")
        await fulfillment(of: [connected], timeout: 2)
        let fitted = expectation(description: "Fit sent for latest geometry")
        let fitObserver = controller.$selectedResolutionPreset.dropFirst().filter { $0 == .fitScreen }
            .sink { _ in fitted.fulfill() }
        controller.updateViewport(CGSize(width: 400, height: 800))
        controller.updateViewport(CGSize(width: 800, height: 400))
        await fulfillment(of: [fitted], timeout: 2)
        fitObserver.cancel()
        let configs = transport.configurations
        XCTAssertEqual(configs.count, 1)
        let config = try XCTUnwrap(configs.first)
        let expected = try XCTUnwrap(MobileResolutionPreset.fitScreen.size(for: CGSize(width: 800, height: 400)))
        XCTAssertEqual(try config.uint32BE(at: 12 + 0x9c + 8), UInt32(expected.width))
        XCTAssertEqual(try config.uint32BE(at: 12 + 0x9c + 12), UInt32(expected.height))

        let fixed = expectation(description: "Fixed preset selected")
        let fixedObserver = controller.$selectedResolutionPreset.filter { $0 == .fullHD }.sink { _ in fixed.fulfill() }
        defer { fixedObserver.cancel() }
        controller.requestResolution(.fullHD)
        await fulfillment(of: [fixed], timeout: 2)
        let count = transport.configurations.count
        controller.updateViewport(CGSize(width: 400, height: 800))
        // Wait beyond the production debounce interval to detect an unwanted request.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.configurations.count, count)
        XCTAssertEqual(controller.selectedResolutionPreset, .fullHD)
    }

    func testLateCancelledAttemptCannotOverwriteNewAttempt() async throws {
        for lateError in [CancellationError() as any Error, TestError.unexpectedAuthentication] {
            let firstEntered = expectation(description: "First attempt entered")
            let secondEntered = expectation(description: "Second attempt entered")
            let authenticator = SuspendedAuthenticator { index in
                (index == 0 ? firstEntered : secondEntered).fulfill()
            }
            let controller = MobileSessionController(
                endpoint: try ConnectionEndpoint("test.local"), authenticator: authenticator
            )
            let firstTask = try XCTUnwrap(controller.connect(username: "viewer", password: "test"))
            await fulfillment(of: [firstEntered], timeout: 2)
            controller.disconnect()
            let secondTask = try XCTUnwrap(controller.connect(username: "viewer", password: "test"))
            await fulfillment(of: [secondEntered], timeout: 2)
            await authenticator.fail(0, error: lateError)
            await firstTask.value
            XCTAssertEqual(controller.state, .connecting)
            controller.disconnect()
            XCTAssertTrue(secondTask.isCancelled)
            await authenticator.fail(1, error: CancellationError())
            await secondTask.value
        }
    }

    func testSavedCredentialsMustMatchConfiguredUsername() async throws {
        let credentials = try ScreenSharingCredentials(username: "viewer", password: "test")
        let controller = MobileSessionController(
            endpoint: try ConnectionEndpoint("studio-mac.local"),
            credentialStore: SignInTestCredentialStore(credentials: credentials)
        )
        let unspecified = await controller.savedCredentials()
        let matching = await controller.savedCredentials(preferredUsername: " viewer ")
        let different = await controller.savedCredentials(preferredUsername: "other-user")
        XCTAssertEqual(unspecified, credentials)
        XCTAssertEqual(matching, credentials)
        XCTAssertNil(different)
    }

    func testUnavailableCredentialsFallBackToManualSignIn() async throws {
        for fails in [false, true] {
            let controller = MobileSessionController(
                endpoint: try ConnectionEndpoint("studio-mac.local"),
                credentialStore: SignInTestCredentialStore(credentials: nil, fails: fails)
            )
            let credentials = await controller.savedCredentials()
            XCTAssertNil(credentials)
            XCTAssertEqual(controller.state, .idle)
        }
    }

    func testCancelledCredentialLookupCannotTriggerAutomaticSignIn() async throws {
        let controller = MobileSessionController(
            endpoint: try ConnectionEndpoint("studio-mac.local"),
            credentialStore: SignInTestCredentialStore(credentials: try ScreenSharingCredentials(username: "viewer", password: "test"))
        )
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.savedCredentials()
        }
        let credentials = await task.value
        XCTAssertNil(credentials)
    }

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

private struct SignInTestCredentialStore: CredentialStoring {
    let credentials: ScreenSharingCredentials?
    var fails = false

    func load(for endpoint: ConnectionEndpoint) throws -> ScreenSharingCredentials? {
        if fails { throw TestError.unexpectedAuthentication }
        return credentials
    }
    func save(_ credentials: ScreenSharingCredentials, for endpoint: ConnectionEndpoint) throws {}
    func delete(for endpoint: ConnectionEndpoint) throws {}
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

private actor SuspendedAuthenticator: RFBAuthenticating {
    let entered: @Sendable (Int) -> Void
    var attempts = [CheckedContinuation<RFBAuthenticatedSession, any Error>]()

    init(entered: @escaping @Sendable (Int) -> Void) { self.entered = entered }

    func connect(to endpoint: ConnectionEndpoint, credentials: ScreenSharingCredentials,
                 sharingType: ScreenSharingType) async throws -> RFBAuthenticatedSession {
        try await withCheckedThrowingContinuation { continuation in
            attempts.append(continuation)
            entered(attempts.count - 1)
        }
    }

    func fail(_ index: Int, error: any Error) { attempts[index].resume(throwing: error) }
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

private struct ViewportNegotiator: AppleControlChannelNegotiating, AppleMediaNegotiating {
    func enableEncryption(for session: RFBAuthenticatedSession, displaySizes: [AppleDynamicResolutionSize]) async throws -> AppleEncryptedRecordLayer {
        let layer = AppleEncryptedRecordLayer(keys: try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16), initializationVector: Data(repeating: 0x22, count: 16)
        ))
        session.install(recordLayer: layer)
        return layer
    }

    func negotiate(_ session: RFBAuthenticatedSession, displayCount: Int) async throws -> AppleMediaNegotiationResult {
        AppleMediaNegotiationResult(
            keys: AppleMediaKeys(audioViewer: Data(repeating: 1, count: 46), audioServer: Data(repeating: 2, count: 46),
                                 videoViewer: Data(repeating: 3, count: 46), videoServer: Data(repeating: 4, count: 46)),
            canvas: AppleCanvas(width: 1440, height: 900, tileCount: 4), videoSynchronizationSource: 1,
            configuration: Data([0x1c, 0, 0, 0]), pendingMessages: []
        )
    }
}

private struct ViewportVideoStarter: AppleVideoStreamStarting {
    func startVideo(for session: RFBAuthenticatedSession, negotiation: AppleMediaNegotiationResult,
                    decoderMode: AppleVideoDecoderMode) throws {
        session.install(videoStream: try AppleVideoStream(receiver: ViewportReceiver(), video: negotiation.videos[0], decoderMode: decoderMode))
    }
}

private final class ViewportReceiver: AppleMediaReceiving, @unchecked Sendable {
    func startVideoDelivery(mediaStreamIndex: Int, on deliveryQueue: DispatchQueue, handler: @escaping AppleVideoDatagramHandler) throws {}
    func stopVideoDelivery(mediaStreamIndex: Int) {}
    func videoReceiveBufferConfiguration(mediaStreamIndex: Int) -> AppleMediaReceiveBufferConfiguration? { nil }
    func drainControlPackets() -> [Data] { [] }
    func sendControl(_ datagram: Data) throws {}
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws {}
    func configureRemotePorts(_ ports: AppleMediaPorts) throws {}
    func stopPunching() {}
    func close() {}
}

private final class ViewportTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let peer: AppleEncryptedRecordLayer
    private var messages = [Data]()
    var configurations: [Data] { lock.withLock { messages.filter { $0.first == 0x1d } } }

    init() throws {
        peer = AppleEncryptedRecordLayer(keys: try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16), initializationVector: Data(repeating: 0x22, count: 16)
        ))
    }
    func start(timeout: Duration) async throws {}
    func send(_ data: Data) async throws {
        try lock.withLock { messages.append(try peer.decrypt(Data(data.dropFirst(2)))) }
    }
    func receiveExactly(_ length: Int) async throws -> Data {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func cancel() {}
}
