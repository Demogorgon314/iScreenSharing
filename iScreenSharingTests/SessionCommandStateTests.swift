import AppKit
import Combine
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class SessionCommandStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionCommandStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadsAndPersistsPresentationChoices() throws {
        let preferences = SessionFeaturePreferences(defaults: defaults)
        preferences.setFixedDisplayScale(1.25)
        preferences.setSynchronizesVideoPresentation(false)
        preferences.setShowsVideoPerformanceOverlay(true)
        preferences.setVideoPerformanceLevel(.detailed)
        preferences.setVideoDecoderMode(.videoProcessing)
        preferences.setShowsMetalPerformanceHUD(true)
        let state = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "command-state.test"),
            preferences: preferences
        )

        XCTAssertEqual(state.displayScale.fixedScale, 1.25)
        XCTAssertFalse(state.synchronizesVideoPresentation)
        XCTAssertTrue(state.showsVideoPerformanceOverlay)
        XCTAssertEqual(state.videoPerformanceLevel, .detailed)
        XCTAssertEqual(state.videoDecoderMode, .videoProcessing)
        XCTAssertTrue(state.showsMetalPerformanceHUD)

        state.setScalesToFit(true)
        state.setSynchronizesVideoPresentation(true)
        state.setShowsVideoPerformanceOverlay(false)
        state.setVideoPerformanceLevel(.compact)
        state.setVideoDecoderMode(.videoToolboxSynchronized)
        state.setShowsMetalPerformanceHUD(false)

        let restored = SessionFeaturePreferences(defaults: defaults)
        XCTAssertNil(restored.fixedDisplayScale)
        XCTAssertTrue(restored.synchronizesVideoPresentation)
        XCTAssertFalse(restored.showsVideoPerformanceOverlay)
        XCTAssertEqual(restored.videoPerformanceLevel, .compact)
        XCTAssertEqual(restored.videoDecoderMode, .videoToolboxSynchronized)
        XCTAssertFalse(restored.showsMetalPerformanceHUD)
    }

    func testRouterTracksTheMostRecentlyActivatedSession() throws {
        let router = ActiveSessionCommandRouter()
        let first = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "first.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let second = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "second.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()

        router.activate(first, for: firstWindow)
        XCTAssertTrue(router.active === first)

        router.activate(second, for: secondWindow)
        XCTAssertTrue(router.active === second)

        router.deactivate(window: firstWindow)
        XCTAssertTrue(router.active === second)

        router.deactivate(window: secondWindow)
        XCTAssertNil(router.active)
    }

    func testRouterForwardsChangesFromTheActiveSessionOnly() throws {
        let router = ActiveSessionCommandRouter()
        let active = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "active.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let inactive = SessionCommandState(
            endpoint: try ConnectionEndpoint(host: "inactive.test"),
            preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let window = makeWindow()
        router.activate(active, for: window)

        var changeCount = 0
        let subscription = router.objectWillChange.sink { changeCount += 1 }

        inactive.setSynchronizesVideoPresentation(false)
        XCTAssertEqual(changeCount, 0)

        active.setSynchronizesVideoPresentation(false)
        XCTAssertEqual(changeCount, 1)
        withExtendedLifetime(subscription) { }
    }

    func testStandardSessionPublishesAndAppliesLiveQualityChanges() async throws {
        let transport = SessionCommandTransport()
        let endpoint = try ConnectionEndpoint(host: "standard-quality.test")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)
        var persistedQuality: StandardRFBQuality?
        let state = SessionCommandState(
            endpoint: endpoint,
            session: session,
            preferences: SessionFeaturePreferences(defaults: defaults),
            standardQualityDidChange: { persistedQuality = $0 }
        )

        XCTAssertTrue(state.canChangeStandardQuality)
        XCTAssertEqual(state.standardQuality, .high)

        state.setStandardQuality(.balanced)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while (stream.currentQuality != .balanced || persistedQuality != .balanced),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.standardQuality, .balanced)
        XCTAssertEqual(stream.currentQuality, .balanced)
        XCTAssertEqual(persistedQuality, .balanced)
        XCTAssertEqual(transport.sentMessages, [
            StandardRFBMessages.setEncodings(for: .balanced),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
        ])
    }

    func testRapidQualityRoundTripFinishesAtTheLastSelectedLevel() async throws {
        let transport = SessionCommandTransport(sendDelay: .milliseconds(50))
        let endpoint = try ConnectionEndpoint(host: "quality-round-trip.test")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .standard,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 2,
                height: 1,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test VNC"
            ),
            transport: transport
        )
        let stream = try StandardRFBVideoStream(session: session, quality: .high)
        session.install(videoStream: stream)
        let state = SessionCommandState(
            endpoint: endpoint,
            session: session,
            preferences: SessionFeaturePreferences(defaults: defaults)
        )

        state.setStandardQuality(.medium)
        let clock = ContinuousClock()
        let firstSendDeadline = clock.now.advanced(by: .seconds(1))
        while transport.sentMessages.isEmpty, clock.now < firstSendDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        state.setStandardQuality(.high)

        let completionDeadline = clock.now.advanced(by: .seconds(1))
        while (transport.sentMessages.count < 4 || stream.currentQuality != .high),
              clock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.standardQuality, .high)
        XCTAssertEqual(stream.currentQuality, .high)
        XCTAssertEqual(transport.sentMessages, [
            StandardRFBMessages.setEncodings(for: .medium),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
            StandardRFBMessages.setEncodings(for: .high),
            AppleRFBMessages.framebufferUpdateRequest(width: 2, height: 1),
        ])
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }
}

private final class SessionCommandTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let sendDelay: Duration?
    private var sent = [Data]()

    init(sendDelay: Duration? = nil) {
        self.sendDelay = sendDelay
    }

    var sentMessages: [Data] {
        withLock { sent }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        withLock { sent.append(data) }
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() { }
}
