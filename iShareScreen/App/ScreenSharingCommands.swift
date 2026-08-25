import AppKit
import SwiftUI

struct ScreenSharingCommands: Commands {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var sessionCommands: ActiveSessionCommandRouter
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.connectionLibraryLayout) private var connectionLibraryLayout
    @FocusedValue(\.connectionLibraryActions) private var connectionLibraryActions
    @AppStorage(SessionToolbarPreferences.isVisibleKey)
    private var sessionToolbarIsVisible = true
    @AppStorage(SessionToolbarPreferences.displayModeKey)
    private var sessionToolbarDisplayMode = SessionToolbarDisplayMode.iconOnly
    private let documents = ConnectionDocumentService()

    var body: some Commands {
        connectionCommands
        viewCommands
        toolbarCommands
        replaceSystemToolbarCommands
    }

    private var toolbarCommands: some Commands {
        CommandMenu("Toolbar") {
            Toggle("Show Toolbar", isOn: sessionToolbarVisibilityBinding)
                .disabled(activeSession == nil)
            Divider()
            Picker("Display Mode", selection: sessionToolbarDisplayModeBinding) {
                ForEach(SessionToolbarDisplayMode.allCases) { displayMode in
                    Text(displayMode.title).tag(displayMode)
                }
            }
            .disabled(activeSession == nil || !sessionToolbarIsVisible)
            Divider()
            Toggle("Scale to Fit", isOn: displayScalingBinding)
                .disabled(activeSession == nil)
            Button("Send Clipboard") {
                activeSession?.sendClipboard()
            }
            .disabled(activeSession?.canSendClipboard != true)
            Toggle("Share Input Source", isOn: keyboardInputSourceBinding)
                .disabled(activeSession?.canShareKeyboardInputSource != true)
            Divider()
            Toggle("Observe Mode", isOn: observationModeBinding)
                .disabled(activeSession?.canToggleObservationMode != true)
            Toggle("Dynamic Resolution", isOn: dynamicResolutionBinding)
                .disabled(activeSession?.canUseDynamicResolution != true)
            Toggle("Synchronize Video", isOn: videoSyncBinding)
                .disabled(activeSession == nil)
            Toggle("Mute Audio", isOn: audioMutedBinding)
                .disabled(activeSession?.hasAudio != true)
            Divider()
            Toggle("Video Performance", isOn: videoPerformanceBinding)
                .disabled(activeSession == nil)
            Toggle("Detailed Video Metrics", isOn: detailedVideoMetricsBinding)
                .disabled(activeSession?.showsVideoPerformanceOverlay != true)
            Toggle("Metal Performance HUD", isOn: metalPerformanceHUDBinding)
                .disabled(activeSession == nil)
            Divider()
            ForEach(AppleRemoteSystemCommand.allCases, id: \.self) { command in
                Button(command.title) { activeSession?.perform(command) }
                    .disabled(activeSession?.canPerform(command) != true)
            }
        }
    }

    private var replaceSystemToolbarCommands: some Commands {
        CommandGroup(replacing: .toolbar) {
            Button(sessionToolbarIsVisible ? "Hide Toolbar" : "Show Toolbar") {
                sessionToolbarVisibilityBinding.wrappedValue.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(activeSession == nil)
        }
    }

    @CommandsBuilder
    private var connectionCommands: some Commands {
        CommandMenu("Connection") {
            Button("New…") {
                openWindow(id: "new-connection")
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Open…") {
                Task {
                    do {
                        if let endpoint = try await documents.openLocation() {
                            openWindow(id: "authentication", value: endpoint)
                        }
                    } catch {
                        ConnectionDocumentService.present(error)
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(store.recentConnections) { connection in
                    Button(connection.name) {
                        openWindow(id: "authentication", value: connection.endpoint)
                    }
                }
                Divider()
                Button("Clear Menu") { store.clearRecentConnections() }
                    .disabled(store.recentConnections.isEmpty)
            }
            Divider()
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(activeSession == nil)
            Button("Close All") {
                NSApp.windows.filter(\.isVisible).forEach { $0.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            Button("Save As…") {
                guard let endpoint = activeSession?.endpoint else { return }
                Task {
                    do {
                        try await documents.saveLocation(for: endpoint)
                    } catch {
                        ConnectionDocumentService.present(error)
                    }
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(activeSession == nil)
            Divider()
            Button("Find…") { connectionLibraryActions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(connectionLibraryActions == nil)
        }
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(before: .toolbar) {
            Button("as Icons") { connectionLibraryLayout = .icons }
                .disabled(connectionLibraryLayout == nil)
            Button("as List") { connectionLibraryLayout = .list }
                .disabled(connectionLibraryLayout == nil)
            Divider()
            Toggle("Scale to Fit", isOn: displayScalingBinding)
                .disabled(activeSession == nil)
            Toggle("Dynamic Resolution", isOn: dynamicResolutionBinding)
                .disabled(activeSession?.canUseDynamicResolution != true)
            Toggle(
                "Synchronize Video",
                isOn: videoSyncBinding
            )
            .disabled(activeSession == nil)
            Button("High Dynamic Range") { }
                .disabled(true)
            Divider()
            Toggle("Observe Mode", isOn: observationModeBinding)
                .disabled(activeSession?.canToggleObservationMode != true)
            Divider()
            Button("Adaptive Quality") { }
                .disabled(true)
            Button("Full Quality") { }
                .disabled(true)
            Divider()
            Button("Actual Size") { activeSession?.actualSize() }
                .disabled(activeSession == nil)
            Button("Zoom In") { activeSession?.zoomIn() }
                .disabled(
                    activeSession == nil
                        || activeSession?.displayScale.fixedScale == AppleVideoDisplayScale.maximum
                )
            Button("Zoom Out") { activeSession?.zoomOut() }
                .disabled(
                    activeSession == nil
                        || activeSession?.displayScale.fixedScale == AppleVideoDisplayScale.minimum
                )
            Divider()
            ForEach([
                AppleRemoteSystemCommand.missionControl,
                .appWindows,
                .desktop,
                .launchpad,
            ], id: \.self) { command in
                Button(command.title) { activeSession?.perform(command) }
                    .disabled(activeSession?.canPerform(command) != true)
            }
        }
    }

    private var activeSession: SessionCommandState? {
        sessionCommands.active
    }

    private var videoSyncBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.synchronizesVideoPresentation ?? false },
            set: { sessionCommands.active?.setSynchronizesVideoPresentation($0) }
        )
    }

    private var dynamicResolutionBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.usesDynamicResolution ?? false },
            set: { sessionCommands.active?.setUsesDynamicResolution($0) }
        )
    }

    private var displayScalingBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.displayScale.scalesToFit ?? false },
            set: { sessionCommands.active?.setScalesToFit($0) }
        )
    }

    private var observationModeBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.isObserving ?? false },
            set: { sessionCommands.active?.setObserving($0) }
        )
    }

    private var keyboardInputSourceBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.sharesKeyboardInputSource ?? false },
            set: { sessionCommands.active?.setSharesKeyboardInputSource($0) }
        )
    }

    private var audioMutedBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.isAudioMuted ?? false },
            set: { sessionCommands.active?.setAudioMuted($0) }
        )
    }

    private var videoPerformanceBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.showsVideoPerformanceOverlay ?? false },
            set: { sessionCommands.active?.setShowsVideoPerformanceOverlay($0) }
        )
    }

    private var detailedVideoMetricsBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.showsDetailedVideoMetrics ?? false },
            set: { sessionCommands.active?.setShowsDetailedVideoMetrics($0) }
        )
    }

    private var metalPerformanceHUDBinding: Binding<Bool> {
        Binding(
            get: { sessionCommands.active?.showsMetalPerformanceHUD ?? false },
            set: { sessionCommands.active?.setShowsMetalPerformanceHUD($0) }
        )
    }

    private var sessionToolbarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { sessionToolbarIsVisible },
            set: { isVisible in
                sessionToolbarIsVisible = isVisible
                applySessionToolbarPreferences(
                    isVisible: isVisible,
                    displayMode: sessionToolbarDisplayMode
                )
            }
        )
    }

    private var sessionToolbarDisplayModeBinding: Binding<SessionToolbarDisplayMode> {
        Binding(
            get: { sessionToolbarDisplayMode },
            set: { displayMode in
                sessionToolbarDisplayMode = displayMode
                applySessionToolbarPreferences(
                    isVisible: sessionToolbarIsVisible,
                    displayMode: displayMode
                )
            }
        )
    }

    private func applySessionToolbarPreferences(
        isVisible: Bool,
        displayMode: SessionToolbarDisplayMode
    ) {
        SessionWindowCoordinator.shared.applyToolbarPreferences(
            isVisible: isVisible,
            displayMode: displayMode
        )
    }
}

struct ConnectionLibraryActions {
    let focusSearch: () -> Void
}

extension FocusedValues {
    var connectionLibraryLayout: Binding<ConnectionLibraryLayout>? {
        get { self[ConnectionLibraryLayoutFocusedKey.self] }
        set { self[ConnectionLibraryLayoutFocusedKey.self] = newValue }
    }

    var connectionLibraryActions: ConnectionLibraryActions? {
        get { self[ConnectionLibraryActionsFocusedKey.self] }
        set { self[ConnectionLibraryActionsFocusedKey.self] = newValue }
    }
}

private struct ConnectionLibraryLayoutFocusedKey: FocusedValueKey {
    typealias Value = Binding<ConnectionLibraryLayout>
}

private struct ConnectionLibraryActionsFocusedKey: FocusedValueKey {
    typealias Value = ConnectionLibraryActions
}
