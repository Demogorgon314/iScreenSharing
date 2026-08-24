import AppKit
import XCTest
@testable import iShareScreen

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
}
