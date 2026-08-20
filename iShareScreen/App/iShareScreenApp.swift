import SwiftUI

@main
struct iShareScreenApp: App {
    @StateObject private var store: ConnectionStore
    @StateObject private var sessions: SessionManager

    init() {
        _store = StateObject(wrappedValue: ConnectionStore())
        _sessions = StateObject(wrappedValue: SessionManager())
    }

    var body: some Scene {
        Window("All Connections", id: "connections") {
            ConnectionsLibraryView(store: store)
        }
        .defaultSize(width: 715, height: 510)
        .windowToolbarStyle(.unified)
        .commands {
            ScreenSharingCommands()
        }

        Window("Screen Sharing", id: "new-connection") {
            NewConnectionView()
        }
        .defaultSize(width: 430, height: 132)
        .windowResizability(.contentSize)

        WindowGroup("", id: "authentication", for: ConnectionEndpoint.self) { $endpoint in
            if let endpoint {
                AuthenticationView(endpoint: endpoint, store: store, sessions: sessions)
            }
        }
        .defaultSize(width: 440, height: 315)
        .windowResizability(.contentSize)

        WindowGroup("Screen Sharing", for: ConnectionEndpoint.self) { $endpoint in
            if let endpoint {
                SessionView(endpoint: endpoint, sessions: sessions)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unifiedCompact)
    }
}

private struct ScreenSharingCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.connectionLibraryLayout) private var connectionLibraryLayout
    @FocusedBinding(\.sessionDisplayScale) private var displayScale
    @FocusedValue(\.sessionModeActions) private var sessionModeActions

    var body: some Commands {
        CommandMenu("Connection") {
            Button("New…") {
                openWindow(id: "new-connection")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(before: .toolbar) {
            Button("as Icons") {
                connectionLibraryLayout = .icons
            }
            .disabled(connectionLibraryLayout == nil)
            Button("as List") {
                connectionLibraryLayout = .list
            }
            .disabled(connectionLibraryLayout == nil)
            Divider()
            Button(displayScale?.scalesToFit != false ? "Turn Scaling Off" : "Turn Scaling On") {
                displayScale?.toggleScaling()
            }
            .disabled(displayScale == nil)
            Divider()
            Button("Actual Size") {
                displayScale?.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(displayScale == nil)
            Button("Zoom In") {
                displayScale?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(displayScale == nil || displayScale?.fixedScale == AppleVideoDisplayScale.maximum)
            Button("Zoom Out") {
                displayScale?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(displayScale == nil || displayScale?.fixedScale == AppleVideoDisplayScale.minimum)
            Divider()
            Button(sessionModeActions?.isObserving == true ? "Switch to Control Mode" : "Switch to Observe Mode") {
                sessionModeActions?.toggle()
            }
            .disabled(sessionModeActions?.canToggle != true)
        }
    }
}

private struct SessionDisplayScaleFocusedKey: FocusedValueKey {
    typealias Value = Binding<AppleVideoDisplayScale>
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

    var sessionModeActions: SessionModeActions? {
        get { self[SessionModeActionsFocusedKey.self] }
        set { self[SessionModeActionsFocusedKey.self] = newValue }
    }
}

private struct ConnectionLibraryLayoutFocusedKey: FocusedValueKey {
    typealias Value = Binding<ConnectionLibraryLayout>
}

struct SessionModeActions {
    let isObserving: Bool
    let canToggle: Bool
    let toggle: () -> Void
}

private struct SessionModeActionsFocusedKey: FocusedValueKey {
    typealias Value = SessionModeActions
}
