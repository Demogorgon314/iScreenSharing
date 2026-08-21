import AppKit
import SwiftUI

@MainActor
final class SessionWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SessionWindowCoordinator()

    private var windowControllers: [ConnectionEndpoint: NSWindowController] = [:]

    func show(endpoint: ConnectionEndpoint, sessions: SessionManager) {
        if let window = windowControllers[endpoint]?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = SessionView(endpoint: endpoint, sessions: sessions)
            .frame(minWidth: 800, minHeight: 500)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = endpoint.displayName
        window.identifier = NSUserInterfaceItemIdentifier("session-\(endpoint.host)-\(endpoint.port)")
        window.contentViewController = NSHostingController(rootView: content)
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowControllers[endpoint] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let endpoint = windowControllers.first(where: { $0.value.window === window })?.key else {
            return
        }
        windowControllers.removeValue(forKey: endpoint)
    }
}
