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
        .windowToolbarStyle(.unifiedCompact)
    }
}
