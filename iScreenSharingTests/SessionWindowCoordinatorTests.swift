import AppKit
import Foundation
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class SessionWindowCoordinatorTests: XCTestCase {
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
            $0.identifier == identifier && $0.isVisible
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
        endpoint: ConnectionEndpoint
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
            transport: NWConnectionTransport(remoteAddress: remoteAddress)
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

private final class WindowLifecycleVideoStream: SessionVideoStream, @unchecked Sendable {
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
