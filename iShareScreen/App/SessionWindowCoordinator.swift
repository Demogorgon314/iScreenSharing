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
        let autosaveName = frameAutosaveName(for: endpoint)
        let restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !restoredFrame { window.center() }
        window.delegate = self

        let controller = NSWindowController(window: window)
        windowControllers[endpoint] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let endpoint = endpoint(for: window) else { return }
        window.saveFrame(usingName: frameAutosaveName(for: endpoint))
        windowControllers.removeValue(forKey: endpoint)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame(from: notification)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(from: notification)
    }

    private func saveFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let endpoint = endpoint(for: window) else { return }
        window.saveFrame(usingName: frameAutosaveName(for: endpoint))
    }

    private func endpoint(for window: NSWindow) -> ConnectionEndpoint? {
        windowControllers.first(where: { $0.value.window === window })?.key
    }

    private func frameAutosaveName(for endpoint: ConnectionEndpoint) -> String {
        "SessionWindow.\(endpoint.url.absoluteString)"
    }
}
