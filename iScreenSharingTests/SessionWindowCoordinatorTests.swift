import AppKit
import Foundation
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDisplayLayout
import struct ScreenSharingProtocol.AppleDisplayRect
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class SessionWindowCoordinatorTests: XCTestCase {
    func testPrimaryWindowRemainsInFrontAfterAuxiliaryDisplayIsCreated() async throws {
        let suiteName = "SessionWindowCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: SessionToolbarPreferences.isVisibleKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = try ConnectionEndpoint(host: "example.local")
        let session = try makeSession(endpoint: endpoint)
        let streams = [
            WindowLifecycleVideoStream(
                canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
                displayIndex: 0
            ),
            WindowLifecycleVideoStream(
                canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
                displayIndex: 1
            ),
        ]
        streams.forEach { $0.start() }
        session.install(videoStreams: streams)
        let displayLayout = AppleDisplayLayoutModel(expectedDisplayCount: 2)
        session.install(displayLayoutModel: displayLayout)
        session.install(dynamicResolutionModel: AppleDynamicResolutionModel(displayCount: 2))
        let sessions = SessionManager()
        sessions.install(session)
        let coordinator = SessionWindowCoordinator(toolbarPreferencesDefaults: defaults)

        coordinator.show(endpoint: endpoint, sessions: sessions)
        await waitForMainQueue()
        let primary = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "session-example.local-5900-display-1"
                && $0.delegate === coordinator
        })

        // DisplayInfo2 arrives after the leader window is already visible in a
        // real session. Creating the auxiliary window must not bring it above
        // that leader or transfer the active session chrome to Display 2.
        displayLayout.receive(AppleDisplayLayout(
            scaledWidth: 1_920,
            scaledHeight: 540,
            backingWidth: 3_840,
            backingHeight: 1_080,
            displays: [
                AppleDisplayRect(displayID: 1, x: 0, y: 0, width: 1_920, height: 1_080),
                AppleDisplayRect(displayID: 2, x: 1_920, y: 0, width: 1_920, height: 1_080),
            ]
        ))
        await waitForMainQueue()
        let secondary = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "session-example.local-5900-display-2"
                && $0.delegate === coordinator
        })
        defer {
            primary.close()
            session.close()
        }

        XCTAssertFalse(secondary.isKeyWindow)
        XCTAssertLessThan(primary.orderedIndex, secondary.orderedIndex)
        XCTAssertTrue(primary.toolbar?.isVisible == true)
        XCTAssertTrue(secondary.toolbar?.isVisible == true)
        XCTAssertFalse(primary.toolbar === secondary.toolbar)
    }

    func testMiniaturizedSingleWindowPausesAndResumesFrameUpdatesInOrder() async {
        let recorder = WindowFrameUpdateRecorder()
        let controller = SessionWindowFrameUpdateController { message in
            await recorder.record(message)
        }

        controller.setMiniaturized(true, endpointWindowCount: 1)
        controller.setMiniaturized(true, endpointWindowCount: 1)
        controller.setMiniaturized(false, endpointWindowCount: 1)
        controller.setMiniaturized(false, endpointWindowCount: 1)
        await controller.waitForPendingSend()

        let messages = await recorder.messages
        XCTAssertEqual(messages, [
            AppleRFBMessages.autoFramebufferUpdate(intervalMilliseconds: .max),
            AppleRFBMessages.autoFramebufferUpdate(intervalMilliseconds: 0),
        ])
    }

    func testMiniaturizedMultiWindowSessionKeepsFrameUpdatesRunning() async {
        let recorder = WindowFrameUpdateRecorder()
        let controller = SessionWindowFrameUpdateController { message in
            await recorder.record(message)
        }

        controller.setMiniaturized(true, endpointWindowCount: 2)
        controller.setMiniaturized(false, endpointWindowCount: 2)
        await controller.waitForPendingSend()

        let messages = await recorder.messages
        XCTAssertTrue(messages.isEmpty)
    }

    func testWindowDelegateSendsEncryptedPauseWithoutStoppingVideo() async throws {
        let endpoint = try ConnectionEndpoint(host: "example.local")
        let pauseSent = expectation(description: "Pause sent")
        let resumeSent = expectation(description: "Resume sent")
        let transport = WindowFrameUpdateTransport(expectations: [pauseSent, resumeSent])
        let session = try makeSession(endpoint: endpoint, transport: transport)
        let keys = try AppleRecordKeys(
            key: Data((0..<16).map(UInt8.init)),
            initializationVector: Data((16..<32).map(UInt8.init))
        )
        session.install(recordLayer: AppleEncryptedRecordLayer(keys: keys))
        let sessions = SessionManager()
        sessions.install(session)
        let coordinator = SessionWindowCoordinator()
        coordinator.show(endpoint: endpoint, sessions: sessions)
        let identifier = NSUserInterfaceItemIdentifier(
            "session-example.local-5900-display-1"
        )
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == identifier && $0.isVisible && $0.delegate === coordinator
        })
        defer {
            window.close()
            session.close()
        }

        coordinator.windowDidMiniaturize(Notification(
            name: NSWindow.didMiniaturizeNotification,
            object: window
        ))
        coordinator.windowDidMiniaturize(Notification(
            name: NSWindow.didMiniaturizeNotification,
            object: window
        ))
        coordinator.windowDidDeminiaturize(Notification(
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        ))
        coordinator.windowDidDeminiaturize(Notification(
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        ))
        await fulfillment(of: [pauseSent, resumeSent], timeout: 1)

        let expectedLayer = AppleEncryptedRecordLayer(keys: keys)
        XCTAssertEqual(transport.sentMessages, [
            try expectedLayer.encrypt(
                AppleRFBMessages.autoFramebufferUpdate(intervalMilliseconds: .max)
            ),
            try expectedLayer.encrypt(
                AppleRFBMessages.autoFramebufferUpdate(intervalMilliseconds: 0)
            ),
        ])
        XCTAssertEqual(session.videoStream?.state, .streaming)
    }

    func testHidesToolbarWhileEnteringFullScreenAndRestoresItOnExit() {
        let coordinator = SessionWindowCoordinator()
        let window = makeWindow(toolbarIsVisible: true)
        window.titlebarSeparatorStyle = .line

        coordinator.windowWillEnterFullScreen(Notification(
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        ))
        XCTAssertTrue(window.toolbar?.isVisible == true)

        coordinator.windowDidEnterFullScreen(Notification(
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        ))

        XCTAssertFalse(window.toolbar?.isVisible == true)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)

        XCTAssertFalse(window.toolbar?.isVisible == true)

        // AppKit may replace SwiftUI's toolbar while leaving full screen. The
        // restoration must target the toolbar that exists after the transition.
        window.toolbar = NSToolbar(identifier: "ReplacementToolbar")
        window.toolbar?.isVisible = false
        coordinator.windowDidExitFullScreen(Notification(
            name: NSWindow.didExitFullScreenNotification,
            object: window
        ))

        XCTAssertTrue(window.toolbar?.isVisible == true)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)
    }

    func testPreservesAnAlreadyHiddenToolbarAfterLeavingFullScreen() {
        let coordinator = SessionWindowCoordinator()
        let window = makeWindow(toolbarIsVisible: false)

        coordinator.windowWillEnterFullScreen(Notification(
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        ))
        coordinator.windowDidEnterFullScreen(Notification(
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        ))
        coordinator.windowDidExitFullScreen(Notification(
            name: NSWindow.didExitFullScreenNotification,
            object: window
        ))

        XCTAssertFalse(window.toolbar?.isVisible == true)
    }

    func testAppliesSupportedSessionToolbarPresentationOptions() {
        let window = makeWindow(toolbarIsVisible: true)

        SessionToolbarPreferences.apply(
            to: window,
            isVisible: false,
            displayMode: .iconAndText
        )

        XCTAssertFalse(window.toolbar?.isVisible == true)
        XCTAssertEqual(window.toolbar?.displayMode, .iconAndLabel)
        XCTAssertTrue(window.toolbar?.allowsDisplayModeCustomization == true)
        XCTAssertTrue(window.toolbar?.autosavesConfiguration == true)

        SessionToolbarPreferences.apply(
            to: window,
            isVisible: true,
            displayMode: .iconOnly
        )

        XCTAssertTrue(window.toolbar?.isVisible == true)
        XCTAssertEqual(window.toolbar?.displayMode, .iconOnly)
    }

    func testConfiguresSessionWindowWithoutTabbing() {
        let coordinator = SessionWindowCoordinator()
        let window = makeWindow(toolbarIsVisible: true)
        window.tabbingMode = .automatic

        coordinator.configureSessionWindowChrome(window)

        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    func testFixedResolutionWindowFitsAndRestoresTheVideoAspectRatioAfterResize() async {
        let coordinator = SessionWindowCoordinator()
        let window = makeWindow(toolbarIsVisible: true)
        window.setContentSize(NSSize(width: 1_100, height: 700))

        coordinator.configureSessionWindowAspectRatio(
            window,
            videoSize: NSSize(width: 1_920, height: 1_080),
            dynamicResolutionEnabled: false
        )

        XCTAssertEqual(window.contentAspectRatio, .zero)
        XCTAssertEqual(
            window.contentView!.bounds.width / window.contentView!.bounds.height,
            16 / 9,
            accuracy: 0.002
        )
        XCTAssertLessThanOrEqual(window.contentView!.bounds.width, 1_100)
        XCTAssertLessThanOrEqual(window.contentView!.bounds.height, 700)

        window.setContentSize(NSSize(width: 1_000, height: 900))
        coordinator.windowDidEndLiveResize(Notification(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        ))
        await waitForMainQueue()

        XCTAssertEqual(
            window.contentView!.bounds.width / window.contentView!.bounds.height,
            16 / 9,
            accuracy: 0.002
        )
    }

    func testDynamicResolutionDoesNotInterveneInLiveWindowResize() async {
        let coordinator = SessionWindowCoordinator()
        let window = makeWindow(toolbarIsVisible: true)

        coordinator.configureSessionWindowAspectRatio(
            window,
            videoSize: NSSize(width: 1_920, height: 1_080),
            dynamicResolutionEnabled: true
        )

        XCTAssertEqual(window.contentAspectRatio, .zero)
        XCTAssertFalse(coordinator.responds(to: NSSelectorFromString("windowWillResize:toFrameSize:")))

        let resizedContentSize = NSSize(width: 1_000, height: 900)
        window.setContentSize(resizedContentSize)
        coordinator.windowDidEndLiveResize(Notification(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        ))
        await waitForMainQueue()

        XCTAssertEqual(window.contentView!.bounds.size, resizedContentSize)
    }

    func testMapsAppKitToolbarDisplayModesToSupportedPreferences() {
        XCTAssertEqual(
            SessionToolbarDisplayMode(appKitDisplayMode: .iconOnly),
            .iconOnly
        )
        XCTAssertEqual(
            SessionToolbarDisplayMode(appKitDisplayMode: .iconAndLabel),
            .iconAndText
        )
        XCTAssertNil(SessionToolbarDisplayMode(appKitDisplayMode: .labelOnly))
    }

    func testPersistsFirstDisplayModeChosenFromToolbarContextMenu() {
        let suiteName = "SessionWindowCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = SessionWindowCoordinator(
            toolbarPreferencesDefaults: defaults
        )
        let window = makeWindow(toolbarIsVisible: true)

        coordinator.configureSessionWindowChrome(window)
        window.toolbar?.displayMode = .iconAndLabel

        XCTAssertEqual(
            SessionToolbarPreferences.storedDisplayMode(in: defaults),
            .iconAndText
        )
    }

    func testClosesSessionWindowWhenInstalledSessionTerminates() async throws {
        let endpoint = try ConnectionEndpoint(host: "example.local")
        let session = try makeSession(endpoint: endpoint)
        let sessions = SessionManager()
        sessions.install(session)
        let coordinator = SessionWindowCoordinator()
        coordinator.show(endpoint: endpoint, sessions: sessions)
        let identifier = NSUserInterfaceItemIdentifier(
            "session-example.local-5900-display-1"
        )
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == identifier && $0.isVisible && $0.delegate === coordinator
        })

        session.close()
        await waitForMainQueue()
        await waitForMainQueue()

        XCTAssertNil(sessions.session(for: endpoint))
        XCTAssertFalse(window.isVisible)
        window.close()
    }

    private func makeWindow(toolbarIsVisible: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let toolbar = NSToolbar(identifier: "SessionWindowCoordinatorTests")
        window.toolbar = toolbar
        toolbar.isVisible = toolbarIsVisible
        return window
    }

    private func makeSession(
        endpoint: ConnectionEndpoint,
        transport: (any RFBTransport)? = nil
    ) throws -> RFBAuthenticatedSession {
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport ?? NWConnectionTransport(remoteAddress: remoteAddress)
        )
        let stream = WindowLifecycleVideoStream(
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4)
        )
        stream.start()
        session.install(videoStream: stream)
        session.install(displayLayoutModel: AppleDisplayLayoutModel())
        session.install(dynamicResolutionModel: AppleDynamicResolutionModel(isEnabled: false))
        session.install(controlState: AppleSessionControlState(session: session))
        return session
    }

    private func waitForMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

private final class WindowFrameUpdateTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [Data]()
    private var expectations: [XCTestExpectation]

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    var sentMessages: [Data] {
        lock.withWindowFrameUpdateLock { messages }
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        let expectation = lock.withWindowFrameUpdateLock { () -> XCTestExpectation? in
            messages.append(data)
            guard !expectations.isEmpty else { return nil }
            return expectations.removeFirst()
        }
        expectation?.fulfill()
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() { }
}

private extension NSLock {
    func withWindowFrameUpdateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private actor WindowFrameUpdateRecorder {
    private(set) var messages = [Data]()

    func record(_ message: Data) {
        messages.append(message)
    }
}

private final class WindowLifecycleVideoStream: SessionVideoStream, @unchecked Sendable {
    init(canvas: AppleCanvas, displayIndex: Int = 0) {
        super.init(canvas: canvas, displayIndex: displayIndex, tileCount: canvas.tileCount)
    }

    override func start() {
        state = .streaming
    }

    override func close() {
        state = .stopped
    }
}
