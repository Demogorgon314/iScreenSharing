import AppKit
import Combine
import struct ScreenSharingProtocol.AppleDisplayLayout
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import SwiftUI

@MainActor
final class SessionWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = SessionWindowCoordinator()
    let commandRouter = ActiveSessionCommandRouter()

    private struct WindowKey: Hashable {
        let endpoint: ConnectionEndpoint
        let displayIndex: Int
    }

    private struct FullScreenChromeState {
        let toolbarWasVisible: Bool?
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
    }

    private var windowControllers: [WindowKey: NSWindowController] = [:]
    private var commandStates: [ConnectionEndpoint: SessionCommandState] = [:]
    private var layoutSubscriptions: [ConnectionEndpoint: AnyCancellable] = [:]
    private var sessionSubscriptions: [ConnectionEndpoint: AnyCancellable] = [:]
    private var toolbarDisplayModeSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var windowAspectRatioSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var windowVideoAspectRatios: [ObjectIdentifier: CGFloat] = [:]
    private var videoRenderers: [WindowKey: AppleVideoRenderer] = [:]
    private var frameUpdateControllers: [ConnectionEndpoint: SessionWindowFrameUpdateController] = [:]
    private var fullScreenChromeStates: [ObjectIdentifier: FullScreenChromeState] = [:]
    private let toolbarPreferencesDefaults: UserDefaults

    init(toolbarPreferencesDefaults: UserDefaults = .standard) {
        self.toolbarPreferencesDefaults = toolbarPreferencesDefaults
        super.init()
    }

    func show(
        endpoint: ConnectionEndpoint,
        sessions: SessionManager,
        connectionStore: ConnectionStore? = nil
    ) {
        let primaryKey = WindowKey(endpoint: endpoint, displayIndex: 0)
        if let window = windowControllers[primaryKey]?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let session = sessions.session(for: endpoint),
              let displayLayout = session.displayLayoutModel,
              let dynamicResolution = session.dynamicResolutionModel,
              let controlState = session.controlState else { return }

        if session.sharingType == .highPerformance {
            frameUpdateControllers[endpoint] = SessionWindowFrameUpdateController {
                [weak session] message in
                guard let session else { return }
                try await session.sendEncrypted(message)
            }
        }

        showWindow(
            key: primaryKey,
            sessions: sessions,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution,
            controlState: controlState,
            connectionStore: connectionStore,
            disconnectsSessionOnDisappear: true
        )
        observeDisplayLayout(
            displayLayout,
            dynamicResolution: dynamicResolution,
            endpoint: endpoint,
            sessions: sessions
        )
        observeSessionLifecycle(
            session,
            endpoint: endpoint,
            sessions: sessions
        )
        NSApp.activate(ignoringOtherApps: true)
        windowControllers[primaryKey]?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let identifier = ObjectIdentifier(window)
        fullScreenChromeStates.removeValue(forKey: identifier)
        toolbarDisplayModeSubscriptions.removeValue(forKey: identifier)?.cancel()
        windowAspectRatioSubscriptions.removeValue(forKey: identifier)?.cancel()
        windowVideoAspectRatios.removeValue(forKey: identifier)
        guard let key = key(for: window) else { return }
        commandRouter.deactivate(window: window)
        window.saveFrame(usingName: frameAutosaveName(for: key))
        windowControllers.removeValue(forKey: key)

        if !windowControllers.keys.contains(where: { $0.endpoint == key.endpoint }) {
            commandStates.removeValue(forKey: key.endpoint)
            sessionSubscriptions.removeValue(forKey: key.endpoint)?.cancel()
            frameUpdateControllers.removeValue(forKey: key.endpoint)
        }

        guard key.displayIndex == 0 else { return }
        layoutSubscriptions.removeValue(forKey: key.endpoint)?.cancel()
        let auxiliaryWindows = windowControllers
            .filter { $0.key.endpoint == key.endpoint }
            .compactMap(\.value.window)
        auxiliaryWindows.forEach { $0.close() }
    }

    private func observeSessionLifecycle(
        _ session: RFBAuthenticatedSession,
        endpoint: ConnectionEndpoint,
        sessions: SessionManager
    ) {
        sessionSubscriptions[endpoint]?.cancel()
        sessionSubscriptions[endpoint] = sessions.$sessions
            .dropFirst()
            .sink { [weak self, weak session] currentSessions in
                guard currentSessions[endpoint] !== session else { return }
                let windows = self?.windowControllers
                    .filter { $0.key.endpoint == endpoint }
                    .compactMap(\.value.window) ?? []
                windows.forEach { $0.close() }
            }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = key(for: window),
              let commandState = commandStates[key.endpoint] else { return }
        commandRouter.activate(commandState, for: window)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              key(for: window) != nil else { return }
        commandRouter.deactivate(window: window)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateFrameDelivery(from: notification, miniaturized: true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateFrameDelivery(from: notification, miniaturized: false)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame(from: notification)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame(from: notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              windowVideoAspectRatios[ObjectIdentifier(window)] != nil else { return }

        // AppKit 2575.70.56 can trap when a delegate changes the proposed size
        // from inside its interactive resize stack. Let that stack unwind and
        // only then restore fixed-mode geometry. Dynamic mode has no stored
        // ratio and therefore never mutates the window here.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.fitSessionWindowToStoredVideoAspectRatio(window)
        }
    }

    func applyToolbarPreferences(
        isVisible: Bool,
        displayMode: SessionToolbarDisplayMode
    ) {
        for window in windowControllers.values.compactMap(\.window) {
            guard fullScreenChromeStates[ObjectIdentifier(window)] == nil else { continue }
            SessionToolbarPreferences.apply(
                to: window,
                isVisible: isVisible,
                displayMode: displayMode
            )
        }
    }

    func configureSessionWindowChrome(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        SessionToolbarPreferences.applyStoredPreferences(
            to: window,
            defaults: toolbarPreferencesDefaults
        )
        observeToolbarDisplayMode(in: window)
    }

    func configureSessionWindowAspectRatio(
        _ window: NSWindow,
        videoSize: NSSize,
        dynamicResolutionEnabled: Bool
    ) {
        let identifier = ObjectIdentifier(window)
        guard !dynamicResolutionEnabled else {
            windowVideoAspectRatios.removeValue(forKey: identifier)
            return
        }
        guard videoSize.width.isFinite, videoSize.height.isFinite,
              videoSize.width > 0, videoSize.height > 0 else {
            windowVideoAspectRatios.removeValue(forKey: identifier)
            return
        }

        windowVideoAspectRatios[identifier] = videoSize.width / videoSize.height
        guard window.contentView?.inLiveResize != true else { return }
        fitSessionWindowToStoredVideoAspectRatio(window)
    }

    private func fitSessionWindowToStoredVideoAspectRatio(_ window: NSWindow) {
        guard let aspectRatio = windowVideoAspectRatios[ObjectIdentifier(window)],
              aspectRatio.isFinite, aspectRatio > 0 else { return }
        let currentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }

        var fittedSize: NSSize
        if currentSize.width / currentSize.height > aspectRatio {
            fittedSize = NSSize(
                width: currentSize.height * aspectRatio,
                height: currentSize.height
            )
        } else {
            fittedSize = NSSize(
                width: currentSize.width,
                height: currentSize.width / aspectRatio
            )
        }
        fittedSize = Self.clampContentSize(
            fittedSize,
            aspectRatio: aspectRatio,
            minimum: window.contentMinSize,
            maximum: window.contentMaxSize
        )
        guard abs(fittedSize.width - currentSize.width) > 0.5
                || abs(fittedSize.height - currentSize.height) > 0.5 else { return }
        window.setContentSize(fittedSize)
    }

    private static func clampContentSize(
        _ size: NSSize,
        aspectRatio: CGFloat,
        minimum: NSSize,
        maximum: NSSize
    ) -> NSSize {
        var result = size
        if result.width < minimum.width {
            result.width = minimum.width
            result.height = result.width / aspectRatio
        }
        if result.height < minimum.height {
            result.height = minimum.height
            result.width = result.height * aspectRatio
        }
        if result.width > maximum.width {
            result.width = maximum.width
            result.height = result.width / aspectRatio
        }
        if result.height > maximum.height {
            result.height = maximum.height
            result.width = result.height * aspectRatio
        }
        return result
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
        observeToolbarDisplayMode(in: window)
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
        guard let controlState = sessions.session(for: endpoint)?.controlState else { return }
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
                    controlState: controlState,
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
        controlState: AppleSessionControlState,
        connectionStore: ConnectionStore? = nil,
        disconnectsSessionOnDisappear: Bool
    ) {
        guard let session = sessions.session(for: key.endpoint) else { return }
        session.connectionTiming?.record(.windowStarted, index: key.displayIndex)
        let scalesToFitOverride = connectionStore?.connection(for: key.endpoint)?.scalesToFit
        let commandState = commandStates[key.endpoint] ?? SessionCommandState(
            endpoint: key.endpoint,
            session: session,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution,
            controlState: controlState,
            scalesToFitOverride: scalesToFitOverride,
            displayScaleDidChange: { [weak connectionStore] scalesToFit in
                connectionStore?.updateScalesToFit(scalesToFit, for: key.endpoint)
            },
            standardQualityDidChange: { [weak connectionStore] quality in
                connectionStore?.updateStandardQuality(quality, for: key.endpoint)
            }
        )
        commandStates[key.endpoint] = commandState
        let renderer = videoRenderer(
            for: key.endpoint,
            displayIndex: key.displayIndex
        )
        let content = SessionView(
            endpoint: key.endpoint,
            sessions: sessions,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution,
            controlState: controlState,
            commandState: commandState,
            displayIndex: key.displayIndex,
            disconnectsSessionOnDisappear: disconnectsSessionOnDisappear,
            videoRenderer: renderer
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
        configureSessionWindowChrome(window)

        if session.sharingType == .standard {
            // A fully transparent window is not composited, so its display link
            // cannot produce the presentation callback that reveals it. Keep it
            // imperceptibly visible until Metal confirms the first drawable.
            window.alphaValue = 0.01
            renderer.notifyWhenNextFrameIsPresented { [weak window] in
                window?.alphaValue = 1
            }
        }

        let controller = NSWindowController(window: window)
        windowControllers[key] = controller
        observeWindowAspectRatio(
            window,
            displayIndex: key.displayIndex,
            session: session,
            displayLayout: displayLayout,
            dynamicResolution: dynamicResolution
        )
        if key.displayIndex > 0,
           let primaryWindow = windowControllers[
               WindowKey(endpoint: key.endpoint, displayIndex: 0)
           ]?.window {
            // Native auxiliary display controllers order their windows below
            // the session leader. Showing one normally would make it key and
            // make its independent toolbar appear to replace Display 1's.
            window.order(.below, relativeTo: primaryWindow.windowNumber)
        } else {
            controller.showWindow(nil)
        }
        session.connectionTiming?.record(
            .windowOrdered, index: key.displayIndex,
            since: .init(.windowStarted, index: key.displayIndex)
        )
        SessionToolbarPreferences.applyStoredPreferences(
            to: window,
            defaults: toolbarPreferencesDefaults
        )
        observeToolbarDisplayMode(in: window)
    }

    private func observeToolbarDisplayMode(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let identifier = ObjectIdentifier(window)
        toolbarDisplayModeSubscriptions[identifier] = toolbar
            .publisher(for: \.displayMode, options: [.initial, .new])
            .dropFirst()
            .compactMap(SessionToolbarDisplayMode.init(appKitDisplayMode:))
            .removeDuplicates()
            .sink { [weak self] displayMode in
                self?.toolbarDisplayModeDidChange(displayMode)
            }
    }

    private func observeWindowAspectRatio(
        _ window: NSWindow,
        displayIndex: Int,
        session: RFBAuthenticatedSession,
        displayLayout: AppleDisplayLayoutModel,
        dynamicResolution: AppleDynamicResolutionModel
    ) {
        guard let stream = session.videoStream(for: displayIndex) else { return }
        let usesIndependentVideoStreams = session.videoStreams.count > 1
        let identifier = ObjectIdentifier(window)
        windowAspectRatioSubscriptions[identifier] = Publishers.CombineLatest3(
            dynamicResolution.$isEnabled.removeDuplicates(),
            displayLayout.$layout.removeDuplicates(),
            stream.$canvas.removeDuplicates()
        )
        .sink { [weak self, weak window, weak displayLayout] enabled, _, canvas in
            guard let self, let window, let displayLayout else { return }
            let videoSize: NSSize
            if displayLayout.supportsDynamicResolution {
                videoSize = NSSize(
                    width: AppleDynamicResolutionSize.fixed1080p.width,
                    height: AppleDynamicResolutionSize.fixed1080p.height
                )
            } else if !usesIndependentVideoStreams,
                      let sourceRect = displayLayout.sourceRect(for: displayIndex) {
                videoSize = sourceRect.size
            } else {
                videoSize = NSSize(width: canvas.width, height: canvas.height)
            }
            self.configureSessionWindowAspectRatio(
                window,
                videoSize: videoSize,
                dynamicResolutionEnabled: enabled
            )
        }
    }

    private func toolbarDisplayModeDidChange(
        _ displayMode: SessionToolbarDisplayMode
    ) {
        guard SessionToolbarPreferences.storedDisplayMode(
            in: toolbarPreferencesDefaults
        ) != displayMode else { return }
        SessionToolbarPreferences.store(
            displayMode: displayMode,
            in: toolbarPreferencesDefaults
        )
        for window in windowControllers.values.compactMap(\.window) {
            guard window.toolbar?.displayMode != displayMode.appKitDisplayMode else { continue }
            window.toolbar?.displayMode = displayMode.appKitDisplayMode
        }
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

    private func updateFrameDelivery(
        from notification: Notification,
        miniaturized: Bool
    ) {
        guard let window = notification.object as? NSWindow,
              let key = key(for: window),
              let controller = frameUpdateControllers[key.endpoint] else { return }
        let endpointWindowCount = windowControllers.keys.reduce(into: 0) { count, candidate in
            if candidate.endpoint == key.endpoint { count += 1 }
        }
        controller.setMiniaturized(
            miniaturized,
            endpointWindowCount: endpointWindowCount
        )
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
