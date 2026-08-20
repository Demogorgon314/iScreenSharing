import AppKit
import SwiftUI

@main
struct iShareScreenApp: App {
    @NSApplicationDelegateAdaptor(ScreenSharingAppDelegate.self) private var appDelegate
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
            ScreenSharingCommands(store: store)
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
    @ObservedObject var store: ConnectionStore
    @Environment(\.openWindow) private var openWindow
    @FocusedBinding(\.connectionLibraryLayout) private var connectionLibraryLayout
    @FocusedBinding(\.sessionDisplayScale) private var displayScale
    @FocusedValue(\.dynamicResolutionActions) private var dynamicResolutionActions
    @FocusedValue(\.sessionModeActions) private var sessionModeActions
    @FocusedValue(\.sessionEndpoint) private var sessionEndpoint
    @FocusedValue(\.connectionLibraryActions) private var connectionLibraryActions
    private let documents = ConnectionDocumentService()

    var body: some Commands {
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
            Button("Dynamic Resolution") {
                dynamicResolutionActions?.toggle()
            }
            .disabled(dynamicResolutionActions?.canToggle != true)
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
}

private struct DynamicResolutionActionsFocusedKey: FocusedValueKey {
    typealias Value = DynamicResolutionActions
}

private struct ConnectionLibraryLayoutFocusedKey: FocusedValueKey {
    typealias Value = Binding<ConnectionLibraryLayout>
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

private struct SessionModeActionsFocusedKey: FocusedValueKey {
    typealias Value = SessionModeActions
}

private struct SessionEndpointFocusedKey: FocusedValueKey {
    typealias Value = ConnectionEndpoint
}

struct ConnectionLibraryActions {
    let focusSearch: () -> Void
}

private struct ConnectionLibraryActionsFocusedKey: FocusedValueKey {
    typealias Value = ConnectionLibraryActions
}
