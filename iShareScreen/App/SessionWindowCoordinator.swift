import AppKit
import Combine
import SwiftUI

@MainActor
final class SessionWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SessionWindowCoordinator()

    private struct WindowKey: Hashable {
        let endpoint: ConnectionEndpoint
        let displayIndex: Int
    }

    private struct FullScreenChromeState {
        let toolbarWasVisible: Bool?
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
    }

    private var windowControllers: [WindowKey: NSWindowController] = [:]
    private var layoutSubscriptions: [ConnectionEndpoint: AnyCancellable] = [:]
    private var videoRenderers: [WindowKey: AppleVideoRenderer] = [:]
    private var fullScreenChromeStates: [ObjectIdentifier: FullScreenChromeState] = [:]

    func show(endpoint: ConnectionEndpoint, sessions: SessionManager) {
        let primaryKey = WindowKey(endpoint: endpoint, displayIndex: 0)
        if let window = windowControllers[primaryKey]?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let session = sessions.session(for: endpoint),
              let displayLayout = session.displayLayoutModel,
              let dynamicResolution = session.dynamicResolutionModel else { return }

        showWindow(
            key: primaryKey,
            sessions: sessions,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution,
            disconnectsSessionOnDisappear: true
        )
        observeDisplayLayout(
            displayLayout,
            dynamicResolution: dynamicResolution,
            endpoint: endpoint,
            sessions: sessions
        )
        NSApp.activate(ignoringOtherApps: true)
        windowControllers[primaryKey]?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        fullScreenChromeStates.removeValue(forKey: ObjectIdentifier(window))
        guard let key = key(for: window) else { return }
        window.saveFrame(usingName: frameAutosaveName(for: key))
        windowControllers.removeValue(forKey: key)

        guard key.displayIndex == 0 else { return }
        layoutSubscriptions.removeValue(forKey: key.endpoint)?.cancel()
        let auxiliaryWindows = windowControllers
            .filter { $0.key.endpoint == key.endpoint }
            .compactMap(\.value.window)
        auxiliaryWindows.forEach { $0.close() }
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame(from: notification)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(from: notification)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let identifier = ObjectIdentifier(window)
        guard fullScreenChromeStates[identifier] == nil else { return }
        fullScreenChromeStates[identifier] = FullScreenChromeState(
            toolbarWasVisible: window.toolbar?.isVisible,
            titlebarSeparatorStyle: window.titlebarSeparatorStyle
        )
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.toolbar?.isVisible = false
        window.titlebarSeparatorStyle = .none
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let state = fullScreenChromeStates.removeValue(
                  forKey: ObjectIdentifier(window)
              ) else { return }
        if let toolbarWasVisible = state.toolbarWasVisible {
            window.toolbar?.isVisible = toolbarWasVisible
        }
        window.titlebarSeparatorStyle = state.titlebarSeparatorStyle
    }

    private func observeDisplayLayout(
        _ displayLayout: AppleDisplayLayoutModel,
        dynamicResolution: AppleDynamicResolutionModel,
        endpoint: ConnectionEndpoint,
        sessions: SessionManager
    ) {
        layoutSubscriptions[endpoint] = displayLayout.$layout
            .removeDuplicates()
            .sink { [weak self, weak sessions] layout in
                guard let self, let sessions else { return }
                self.updateWindows(
                    for: endpoint,
                    displayLayout: displayLayout,
                    dynamicResolution: dynamicResolution,
                    layout: layout,
                    sessions: sessions
                )
            }
    }

    private func updateWindows(
        for endpoint: ConnectionEndpoint,
        displayLayout: AppleDisplayLayoutModel,
        dynamicResolution: AppleDynamicResolutionModel,
        layout: AppleDisplayLayout?,
        sessions: SessionManager
    ) {
        let displayCount = max(1, layout?.displays.count ?? 1)
        if displayCount > 1 {
            for displayIndex in 1..<displayCount {
                let key = WindowKey(endpoint: endpoint, displayIndex: displayIndex)
                guard windowControllers[key] == nil else { continue }
                showWindow(
                    key: key,
                    sessions: sessions,
                    displayLayout: displayLayout,
                    dynamicResolution: dynamicResolution,
                    disconnectsSessionOnDisappear: false
                )
            }
        }

        let obsoleteWindows = windowControllers
            .filter { key, _ in
                key.endpoint == endpoint && key.displayIndex >= displayCount
            }
            .compactMap(\.value.window)
        obsoleteWindows.forEach { $0.close() }

        for displayIndex in 0..<displayCount {
            let key = WindowKey(endpoint: endpoint, displayIndex: displayIndex)
            guard let window = windowControllers[key]?.window else { continue }
            window.title = windowTitle(for: key, displayCount: displayCount)
        }
    }

    private func showWindow(
        key: WindowKey,
        sessions: SessionManager,
        displayLayout: AppleDisplayLayoutModel,
        dynamicResolution: AppleDynamicResolutionModel,
        disconnectsSessionOnDisappear: Bool
    ) {
        let content = SessionView(
            endpoint: key.endpoint,
            sessions: sessions,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution,
            displayIndex: key.displayIndex,
            disconnectsSessionOnDisappear: disconnectsSessionOnDisappear,
            videoRenderer: videoRenderer(
                for: key.endpoint,
                displayIndex: key.displayIndex
            )
        )
        .frame(minWidth: 800, minHeight: 500)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let displayCount = max(1, displayLayout.displayCount)
        window.title = windowTitle(for: key, displayCount: displayCount)
        window.identifier = NSUserInterfaceItemIdentifier(
            "session-\(key.endpoint.host)-\(key.endpoint.port)-display-\(key.displayIndex + 1)"
        )
        window.contentViewController = NSHostingController(rootView: content)
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.setContentSize(NSSize(width: 1100, height: 700))
        let autosaveName = frameAutosaveName(for: key)
        let restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !restoredFrame {
            if key.displayIndex == 0 {
                window.center()
            } else if let primary = windowControllers[WindowKey(endpoint: key.endpoint, displayIndex: 0)]?.window {
                window.cascadeTopLeft(from: NSPoint(x: primary.frame.minX, y: primary.frame.maxY))
            } else {
                window.center()
            }
        }
        window.delegate = self

        let controller = NSWindowController(window: window)
        windowControllers[key] = controller
        controller.showWindow(nil)
    }

    func videoRenderer(
        for endpoint: ConnectionEndpoint,
        displayIndex: Int
    ) -> AppleVideoRenderer {
        let key = WindowKey(endpoint: endpoint, displayIndex: displayIndex)
        if let renderer = videoRenderers[key] {
            return renderer
        }
        let renderer = AppleVideoRenderer()
        videoRenderers[key] = renderer
        return renderer
    }

    private func saveFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = key(for: window) else { return }
        window.saveFrame(usingName: frameAutosaveName(for: key))
    }

    private func key(for window: NSWindow) -> WindowKey? {
        windowControllers.first(where: { $0.value.window === window })?.key
    }

    private func windowTitle(for key: WindowKey, displayCount: Int) -> String {
        guard displayCount > 1 else { return key.endpoint.displayName }
        return "\(key.endpoint.displayName) — Display \(key.displayIndex + 1)"
    }

    private func frameAutosaveName(for key: WindowKey) -> String {
        let base = "SessionWindow.\(key.endpoint.url.absoluteString)"
        return key.displayIndex == 0 ? base : "\(base).Display\(key.displayIndex + 1)"
    }
}
