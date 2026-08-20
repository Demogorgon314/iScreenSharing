import SwiftUI

@main
struct iShareScreenApp: App {
    @StateObject private var store: ConnectionStore

    init() {
        _store = StateObject(wrappedValue: ConnectionStore())
    }

    var body: some Scene {
        Window("All Connections", id: "connections") {
            ConnectionsLibraryView(store: store)
        }
        .defaultSize(width: 715, height: 510)
        .windowToolbarStyle(.unified)
        .commands {
            ConnectionCommands()
        }

        Window("Screen Sharing", id: "new-connection") {
            NewConnectionView(store: store)
        }
        .defaultSize(width: 430, height: 132)
        .windowResizability(.contentSize)

        WindowGroup("Screen Sharing", for: ConnectionEndpoint.self) { $endpoint in
            if let endpoint {
                SessionView(endpoint: endpoint)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unifiedCompact)
    }
}

private struct ConnectionCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Connection") {
            Button("New Connection…") {
                openWindow(id: "new-connection")
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

