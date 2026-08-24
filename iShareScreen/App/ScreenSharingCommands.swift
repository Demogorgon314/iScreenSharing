import AppKit
import SwiftUI

struct ScreenSharingCommands: Commands {
    @ObservedObject var store: ConnectionStore
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.connectionLibraryLayout) private var connectionLibraryLayout
    @FocusedBinding(\.sessionDisplayScale) private var displayScale
    @FocusedBinding(\.synchronizesVideoPresentation) private var synchronizesVideoPresentation
    @FocusedValue(\.dynamicResolutionActions) private var dynamicResolutionActions
    @FocusedValue(\.sessionModeActions) private var sessionModeActions
    @FocusedValue(\.sessionEndpoint) private var sessionEndpoint
    @FocusedValue(\.connectionLibraryActions) private var connectionLibraryActions
    @FocusedValue(\.remoteSystemActions) private var remoteSystemActions
    @FocusedValue(\.sessionToolbarActions) private var sessionToolbarActions
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
                .disabled(sessionEndpoint == nil)
            Divider()
            Picker("Display Mode", selection: sessionToolbarDisplayModeBinding) {
                ForEach(SessionToolbarDisplayMode.allCases) { displayMode in
                    Text(displayMode.title).tag(displayMode)
                }
            }
            .disabled(sessionEndpoint == nil || !sessionToolbarIsVisible)
            Divider()
            Button(displayScale?.scalesToFit != false ? "Turn Scaling Off" : "Turn Scaling On") {
                displayScale?.toggleScaling()
            }
            .disabled(displayScale == nil)
            Button("Send Clipboard") {
                sessionToolbarActions?.sendClipboard()
            }
            .disabled(sessionToolbarActions?.canSendClipboard != true)
            Toggle("Share Input Source", isOn: keyboardInputSourceBinding)
                .disabled(sessionToolbarActions?.keyboardInputSource?.isEnabled != true)
            Divider()
            Button(sessionModeActions?.isObserving == true ? "Switch to Control Mode" : "Switch to Observe Mode") {
                sessionModeActions?.toggle()
            }
            .disabled(sessionModeActions?.canToggle != true)
            Toggle("Dynamic Resolution", isOn: dynamicResolutionBinding)
                .disabled(dynamicResolutionActions?.canToggle != true)
            Toggle("Synchronize Video", isOn: videoSyncBinding)
                .disabled(synchronizesVideoPresentation == nil)
            Toggle("Mute Audio", isOn: audioMutedBinding)
                .disabled(sessionToolbarActions?.audioMuted?.isEnabled != true)
            Divider()
            Toggle("Video Performance", isOn: videoPerformanceBinding)
                .disabled(sessionToolbarActions == nil)
            Toggle("Metal Performance HUD", isOn: metalPerformanceHUDBinding)
                .disabled(sessionToolbarActions == nil)
            Divider()
            ForEach(AppleRemoteSystemCommand.allCases, id: \.self) { command in
                Button(command.title) { remoteSystemActions?.perform(command) }
                    .disabled(remoteSystemActions?.canPerform(command) != true)
            }
        }
    }

    private var replaceSystemToolbarCommands: some Commands {
        CommandGroup(replacing: .toolbar) {
            Button(sessionToolbarIsVisible ? "Hide Toolbar" : "Show Toolbar") {
                sessionToolbarVisibilityBinding.wrappedValue.toggle()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(sessionEndpoint == nil)
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
            .disabled(sessionEndpoint == nil)
            Button("Close All") {
                NSApp.windows.filter(\.isVisible).forEach { $0.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            Button("Save As…") {
                guard let sessionEndpoint else { return }
                Task {
                    do {
                        try await documents.saveLocation(for: sessionEndpoint)
                    } catch {
                        ConnectionDocumentService.present(error)
                    }
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(sessionEndpoint == nil)
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
            Button(displayScale?.scalesToFit != false ? "Turn Scaling Off" : "Turn Scaling On") {
                displayScale?.toggleScaling()
            }
            .disabled(displayScale == nil)
            Toggle("Dynamic Resolution", isOn: dynamicResolutionBinding)
                .disabled(dynamicResolutionActions?.canToggle != true)
            Toggle(
                "Synchronize Video",
                isOn: videoSyncBinding
            )
            .disabled(synchronizesVideoPresentation == nil)
            Button("High Dynamic Range") { }
                .disabled(true)
            Divider()
            Button(sessionModeActions?.isObserving == true ? "Switch to Control Mode" : "Switch to Observe Mode") {
                sessionModeActions?.toggle()
            }
            .disabled(sessionModeActions?.canToggle != true)
            Divider()
            Button("Adaptive Quality") { }
                .disabled(true)
            Button("Full Quality") { }
                .disabled(true)
            Divider()
            Button("Actual Size") { displayScale?.actualSize() }
                .disabled(displayScale == nil)
            Button("Zoom In") { displayScale?.zoomIn() }
                .disabled(displayScale == nil || displayScale?.fixedScale == AppleVideoDisplayScale.maximum)
            Button("Zoom Out") { displayScale?.zoomOut() }
                .disabled(displayScale == nil || displayScale?.fixedScale == AppleVideoDisplayScale.minimum)
            Divider()
            ForEach([
                AppleRemoteSystemCommand.missionControl,
                .appWindows,
                .desktop,
                .launchpad,
            ], id: \.self) { command in
                Button(command.title) { remoteSystemActions?.perform(command) }
                    .disabled(remoteSystemActions?.canPerform(command) != true)
            }
        }
    }

    private var videoSyncBinding: Binding<Bool> {
        Binding(
            get: { synchronizesVideoPresentation ?? false },
            set: { synchronizesVideoPresentation = $0 }
        )
    }

    private var dynamicResolutionBinding: Binding<Bool> {
        Binding(
            get: { dynamicResolutionActions?.isEnabled ?? false },
            set: { newValue in
                guard newValue != dynamicResolutionActions?.isEnabled else { return }
                dynamicResolutionActions?.toggle()
            }
        )
    }

    private var keyboardInputSourceBinding: Binding<Bool> {
        sessionToolbarActions?.keyboardInputSource?.isOn ?? .constant(false)
    }

    private var audioMutedBinding: Binding<Bool> {
        sessionToolbarActions?.audioMuted?.isOn ?? .constant(false)
    }

    private var videoPerformanceBinding: Binding<Bool> {
        sessionToolbarActions?.showsVideoPerformance ?? .constant(false)
    }

    private var metalPerformanceHUDBinding: Binding<Bool> {
        sessionToolbarActions?.showsMetalPerformanceHUD ?? .constant(false)
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

struct SessionModeActions {
    let isObserving: Bool
    let canToggle: Bool
    let toggle: () -> Void
}

struct DynamicResolutionActions {
    let isEnabled: Bool
    let canToggle: Bool
    let toggle: () -> Void
}

struct ConnectionLibraryActions {
    let focusSearch: () -> Void
}

struct RemoteSystemActions {
    let canPerform: (AppleRemoteSystemCommand) -> Bool
    let perform: (AppleRemoteSystemCommand) -> Void
}

struct SessionToggleActions {
    let isEnabled: Bool
    let isOn: Binding<Bool>
}

struct SessionToolbarActions {
    let canSendClipboard: Bool
    let sendClipboard: () -> Void
    let keyboardInputSource: SessionToggleActions?
    let showsVideoPerformance: Binding<Bool>
    let showsMetalPerformanceHUD: Binding<Bool>
    let audioMuted: SessionToggleActions?
}

extension FocusedValues {
    var connectionLibraryLayout: Binding<ConnectionLibraryLayout>? {
        get { self[ConnectionLibraryLayoutFocusedKey.self] }
        set { self[ConnectionLibraryLayoutFocusedKey.self] = newValue }
    }

    var sessionDisplayScale: Binding<AppleVideoDisplayScale>? {
        get { self[SessionDisplayScaleFocusedKey.self] }
        set { self[SessionDisplayScaleFocusedKey.self] = newValue }
    }

    var synchronizesVideoPresentation: Binding<Bool>? {
        get { self[SynchronizedVideoPresentationFocusedKey.self] }
        set { self[SynchronizedVideoPresentationFocusedKey.self] = newValue }
    }

    var dynamicResolutionActions: DynamicResolutionActions? {
        get { self[DynamicResolutionActionsFocusedKey.self] }
        set { self[DynamicResolutionActionsFocusedKey.self] = newValue }
    }

    var sessionModeActions: SessionModeActions? {
        get { self[SessionModeActionsFocusedKey.self] }
        set { self[SessionModeActionsFocusedKey.self] = newValue }
    }

    var sessionEndpoint: ConnectionEndpoint? {
        get { self[SessionEndpointFocusedKey.self] }
        set { self[SessionEndpointFocusedKey.self] = newValue }
    }

    var connectionLibraryActions: ConnectionLibraryActions? {
        get { self[ConnectionLibraryActionsFocusedKey.self] }
        set { self[ConnectionLibraryActionsFocusedKey.self] = newValue }
    }

    var remoteSystemActions: RemoteSystemActions? {
        get { self[RemoteSystemActionsFocusedKey.self] }
        set { self[RemoteSystemActionsFocusedKey.self] = newValue }
    }

    var sessionToolbarActions: SessionToolbarActions? {
        get { self[SessionToolbarActionsFocusedKey.self] }
        set { self[SessionToolbarActionsFocusedKey.self] = newValue }
    }
}

private struct SessionDisplayScaleFocusedKey: FocusedValueKey {
    typealias Value = Binding<AppleVideoDisplayScale>
}

private struct SynchronizedVideoPresentationFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct DynamicResolutionActionsFocusedKey: FocusedValueKey {
    typealias Value = DynamicResolutionActions
}

private struct ConnectionLibraryLayoutFocusedKey: FocusedValueKey {
    typealias Value = Binding<ConnectionLibraryLayout>
}

private struct SessionModeActionsFocusedKey: FocusedValueKey {
    typealias Value = SessionModeActions
}

private struct SessionEndpointFocusedKey: FocusedValueKey {
    typealias Value = ConnectionEndpoint
}

private struct ConnectionLibraryActionsFocusedKey: FocusedValueKey {
    typealias Value = ConnectionLibraryActions
}

private struct RemoteSystemActionsFocusedKey: FocusedValueKey {
    typealias Value = RemoteSystemActions
}

private struct SessionToolbarActionsFocusedKey: FocusedValueKey {
    typealias Value = SessionToolbarActions
}
