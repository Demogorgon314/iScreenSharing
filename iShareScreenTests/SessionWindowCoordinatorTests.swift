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
